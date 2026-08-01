use super::*;

fn push_auth_event(
    events: &Arc<Mutex<Vec<SessionEvent>>>,
    wakeup: &Arc<Mutex<Option<WakeupCallback>>>,
    kind: &str,
    method: &str,
    message: impl Into<String>,
) {
    push_event(
        events,
        wakeup,
        SessionEvent::new(kind, message).with_method(method),
    );
}

type DynamicAgentClient = AgentClient<Box<dyn AgentStream + Send + Unpin + 'static>>;

#[cfg(unix)]
async fn connect_agent_client() -> Result<DynamicAgentClient, String> {
    AgentClient::connect_env()
        .await
        .map(|agent| agent.dynamic())
        .map_err(|error| error.to_string())
}

#[cfg(windows)]
async fn connect_agent_client() -> Result<DynamicAgentClient, String> {
    if let Ok(agent) = AgentClient::connect_pageant().await {
        return Ok(agent.dynamic());
    }

    let pipe = std::env::var("SSH_AUTH_SOCK")
        .ok()
        .filter(|path| !path.trim().is_empty())
        .unwrap_or_else(|| r"\\.\pipe\openssh-ssh-agent".to_owned());
    AgentClient::<tokio::net::windows::named_pipe::NamedPipeClient>::connect_named_pipe(
        std::ffi::OsString::from(pipe),
    )
    .await
    .map(|agent| agent.dynamic())
    .map_err(|error| error.to_string())
}

pub(crate) async fn authenticate<H: client::Handler>(
    handle: &mut client::Handle<H>,
    username: &str,
    private_key: Option<&str>,
    passphrase: Option<&str>,
    password: Option<&str>,
    events: &Arc<Mutex<Vec<SessionEvent>>>,
    wakeup: &Arc<Mutex<Option<WakeupCallback>>>,
) -> Result<(), String> {
    push_auth_event(
        events,
        wakeup,
        "auth_none_start",
        "none",
        "Trying SSH none authentication.",
    );
    match handle.authenticate_none(username.to_owned()).await {
        Ok(result) if result.success() => {
            push_auth_event(
                events,
                wakeup,
                "auth_success",
                "none",
                "SSH none authentication succeeded.",
            );
            return Ok(());
        }
        Ok(AuthResult::Failure { .. }) => {
            push_auth_event(
                events,
                wakeup,
                "auth_none_rejected",
                "none",
                "SSH none authentication was rejected.",
            );
        }
        Err(error) => {
            push_auth_event(
                events,
                wakeup,
                "auth_none_failed",
                "none",
                format!("SSH none authentication failed: {error}"),
            );
            return Err(error.to_string());
        }
        Ok(AuthResult::Success) => {
            push_auth_event(
                events,
                wakeup,
                "auth_success",
                "none",
                "SSH none authentication succeeded.",
            );
            return Ok(());
        }
    }

    if let Some(private_key) = private_key {
        push_auth_event(
            events,
            wakeup,
            "auth_key_start",
            "public_key",
            "Trying configured private key authentication.",
        );
        let private_key = match decode_secret_key(private_key, passphrase) {
            Ok(private_key) => private_key,
            Err(KeyError::KeyIsEncrypted) if passphrase.is_none() => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_passphrase_required",
                    "public_key",
                    "Configured private key requires a passphrase.",
                );
                return Err("configured private key requires a passphrase".to_owned());
            }
            Err(error) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_key_failed",
                    "public_key",
                    format!("Failed to decode configured private key: {error}"),
                );
                return Err(format!("failed to decode private key: {error}"));
            }
        };
        let hash_alg = handle
            .best_supported_rsa_hash()
            .await
            .map_err(|error| error.to_string())?
            .flatten();
        match handle
            .authenticate_publickey(
                username.to_owned(),
                PrivateKeyWithHashAlg::new(Arc::new(private_key), hash_alg),
            )
            .await
        {
            Ok(result) if result.success() => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_success",
                    "public_key",
                    "Configured private key authentication succeeded.",
                );
                return Ok(());
            }
            Ok(AuthResult::Failure { .. }) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_key_rejected",
                    "public_key",
                    "Configured private key authentication was rejected.",
                );
            }
            Err(error) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_key_failed",
                    "public_key",
                    format!("Configured private key authentication failed: {error}"),
                );
                return Err(error.to_string());
            }
            Ok(AuthResult::Success) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_success",
                    "public_key",
                    "Configured private key authentication succeeded.",
                );
                return Ok(());
            }
        }

        push_auth_event(
            events,
            wakeup,
            "auth_failed",
            "public_key",
            "Server rejected configured private key authentication.",
        );
        return Err("server rejected configured private key authentication".to_owned());
    }

    if let Some(password) = password {
        push_auth_event(
            events,
            wakeup,
            "auth_password_start",
            "password",
            "Trying password authentication.",
        );
        match handle
            .authenticate_password(username.to_owned(), password.to_owned())
            .await
        {
            Ok(result) if result.success() => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_success",
                    "password",
                    "Password authentication succeeded.",
                );
                return Ok(());
            }
            Ok(AuthResult::Failure { .. }) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_password_rejected",
                    "password",
                    "Password authentication was rejected.",
                );
            }
            Err(error) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_password_failed",
                    "password",
                    format!("Password authentication failed: {error}"),
                );
                return Err(error.to_string());
            }
            Ok(AuthResult::Success) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_success",
                    "password",
                    "Password authentication succeeded.",
                );
                return Ok(());
            }
        }
    }

    push_auth_event(
        events,
        wakeup,
        "auth_agent_start",
        "agent",
        "Trying SSH agent authentication.",
    );
    let mut agent = connect_agent_client().await.map_err(|error| {
        push_auth_event(
            events,
            wakeup,
            "auth_agent_unavailable",
            "agent",
            format!("No usable SSH agent was available: {error}"),
        );
        format!("server rejected none/password authentication and no usable SSH agent was available: {error}")
    })?;
    let identities = agent.request_identities().await.map_err(|error| {
        push_auth_event(
            events,
            wakeup,
            "auth_agent_failed",
            "agent",
            format!("Failed to list SSH agent identities: {error}"),
        );
        format!("failed to list SSH agent identities: {error}")
    })?;
    push_auth_event(
        events,
        wakeup,
        "auth_agent_identities",
        "agent",
        format!("SSH agent returned {} identities.", identities.len()),
    );
    for (index, identity) in identities.into_iter().enumerate() {
        let key = identity.public_key().into_owned();
        push_auth_event(
            events,
            wakeup,
            "auth_agent_identity_start",
            "agent",
            format!("Trying SSH agent identity {}.", index + 1),
        );
        match handle
            .authenticate_publickey_with(username.to_owned(), key, None, &mut agent)
            .await
        {
            Ok(result) if result.success() => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_success",
                    "agent",
                    format!("SSH agent identity {} succeeded.", index + 1),
                );
                return Ok(());
            }
            Ok(_) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_agent_identity_rejected",
                    "agent",
                    format!("SSH agent identity {} was rejected.", index + 1),
                );
            }
            Err(error) => {
                push_auth_event(
                    events,
                    wakeup,
                    "auth_agent_failed",
                    "agent",
                    format!("SSH agent authentication failed: {error}"),
                );
                return Err(error.to_string());
            }
        }
    }

    push_auth_event(
        events,
        wakeup,
        "auth_failed",
        "agent",
        "Server rejected none/password/agent authentication.",
    );
    Err("server rejected none/password/agent authentication".to_owned())
}
