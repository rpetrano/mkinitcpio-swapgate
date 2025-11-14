use std::process::Command;
use std::time::Duration;
use std::os::fd::AsRawFd;

use tokio::time::sleep;
use zbus::{MatchRule, MessageStream};
use zbus::zvariant::OwnedFd;
use zbus::message::Type as MsgType;
use futures_lite::stream::StreamExt;

const WHO: &str = "nouveau-sleep-daemon";
const WHY: &str = "Turn off NVIDIA outputs before sleep";
const MODE: &str = "delay";
const WHAT: &str = "sleep";

#[derive(Debug)]
enum InhibitorState {
    None,
    Holding(OwnedFd),
    WaitingForResume,
}

#[tokio::main]
async fn main() -> zbus::Result<()> {
    // connect to system bus
    let connection = zbus::Connection::system().await?;

    // initial inhibitor
    let mut state = acquire_inhibitor(&connection).await.unwrap_or(InhibitorState::None);

    // subscribe to PrepareForSleep signals
    let rule = MatchRule::builder()
        .msg_type(MsgType::Signal)
        .sender("org.freedesktop.login1")?
        .interface("org.freedesktop.login1.Manager")?
        .member("PrepareForSleep")?
        .build();

    let mut stream = MessageStream::for_match_rule(
        rule,
        &connection,
        None,
    ).await?;

    loop {
        tokio::select! {
            maybe_msg = stream.next() => {
                let msg = match maybe_msg {
                    Some(Ok(m)) => m,
                    Some(Err(e)) => {
                        eprintln!("[nouveau-daemon] error receiving signal: {e}");
                        continue;
                    }
                    None => {
                        eprintln!("[nouveau-daemon] signal stream ended, reconnecting in 2s");
                        sleep(Duration::from_secs(2)).await;
                        // in real code: re-create connection + stream
                        continue;
                    }
                };

                // expect a single boolean argument
                let going_down: bool = match msg.body().deserialize() {
                    Ok(b) => b,
                    Err(e) => {
                        eprintln!("[nouveau-daemon] failed to deserialize PrepareForSleep body: {e}");
                        return Ok(()); // or continue/ignore this msg
                    }
                };

                if going_down {
                    // PrepareForSleep(true)
                    eprintln!("[nouveau-daemon] PrepareForSleep(true)");
                    match state {
                        InhibitorState::Holding(fd) => {
                            // run pre script
                            run_script("pre");

                            // drop fd to release inhibitor
                            drop(fd);
                            state = InhibitorState::WaitingForResume;
                            eprintln!("[nouveau-daemon] released inhibitor, waiting for resume");
                        }
                        _ => {
                            // no inhibitor but we still try to run pre once
                            run_script("pre");
                        }
                    }
                } else {
                    // PrepareForSleep(false) – system woke up
                    eprintln!("[nouveau-daemon] PrepareForSleep(false)");
                    // run post script
                    run_script("post");

                    // re-acquire inhibitor
                    match acquire_inhibitor(&connection).await {
                        Ok(st) => {
                            state = st;
                            eprintln!("[nouveau-daemon] re-acquired inhibitor after resume");
                        }
                        Err(e) => {
                            eprintln!("[nouveau-daemon] failed to re-acquire inhibitor: {e}");
                            state = InhibitorState::None;
                        }
                    }
                }
            }
        }
    }
}

fn run_script(arg: &str) {
    eprintln!("[nouveau-daemon] running {arg} script");
    let status = Command::new("/usr/local/bin/nouveau-hibernation.sh")
        .arg(arg)
        .status();

    match status {
        Ok(s) if s.success() => {
            eprintln!("[nouveau-daemon] {arg} script finished OK");
        }
        Ok(s) => {
            eprintln!("[nouveau-daemon] {arg} script exited with {s}");
        }
        Err(e) => {
            eprintln!("[nouveau-daemon] failed to run {arg} script: {e}");
        }
    }
}

async fn acquire_inhibitor(conn: &zbus::Connection) -> zbus::Result<InhibitorState> {
    eprintln!("[nouveau-daemon] acquiring delay inhibitor");

    // Call Inhibit("sleep","WHO","WHY","delay") → returns fd
    let reply = conn
        .call_method(
            Some("org.freedesktop.login1"),
            "/org/freedesktop/login1",
            Some("org.freedesktop.login1.Manager"),
            "Inhibit",
            &(WHAT, WHO, WHY, MODE),
        )
        .await?;

    // extract returned fd
    let fd: OwnedFd = reply.body().deserialize()?;
    eprintln!("[nouveau-daemon] inhibitor acquired (fd={})", fd.as_raw_fd());

    Ok(InhibitorState::Holding(fd))
}

