import Foundation

/// Classifies output from `sftp` during the authentication phase into either an
/// interactive prompt we need to surface to the user, or "still waiting".
enum SFTPPrompt: Equatable {
    /// Password / "user's password" prompt. The associated string is what to display in the sheet.
    case password(label: String)
    /// Passphrase for a key file. Associated value is the key path the prompt names.
    case passphrase(keyPath: String)
    /// First-time host-key verification. Associated values are host, key type ("ED25519" / "RSA" / ...),
    /// and fingerprint string ("SHA256:abc…").
    case hostKey(host: String, keyType: String, fingerprint: String)
    /// REMOTE HOST IDENTIFICATION HAS CHANGED — destructive sheet.
    case hostKeyMismatch(host: String)
    /// Generic keyboard-interactive challenge (OTP, Duo, custom PAM prompt, etc.).
    /// The associated string is the raw prompt line from the server. Should NOT be saved to Keychain.
    case keyboardInteractive(prompt: String)
}

enum SFTPPromptClassifier {

    /// Tries to identify an interactive prompt at the tail of `buffer`.
    /// Returns `nil` if the buffer does not currently end in a recognised prompt.
    /// Callers should call this on every append while in `.authenticating`.
    static func classify(_ buffer: String) -> SFTPPrompt? {
        // Check host-key mismatch FIRST — it's a multi-line warning that may precede a "yes/no" prompt.
        if buffer.range(of: "REMOTE HOST IDENTIFICATION HAS CHANGED") != nil {
            // Try to extract the host from the surrounding "Host key verification failed" context.
            let host = extractMismatchHost(buffer) ?? "remote host"
            return .hostKeyMismatch(host: host)
        }

        // First-time host-key prompt.
        if let m = firstTimeHostKey(in: buffer) {
            return m
        }

        // Passphrase prompts come from ssh-keygen / sftp when a key file is encrypted.
        if let kp = passphraseKeyPath(in: buffer) {
            return .passphrase(keyPath: kp)
        }

        // Password prompts.
        if let label = passwordLabel(in: buffer) {
            return .password(label: label)
        }

        // Generic keyboard-interactive fallback: any prompt line ending in ":" that wasn't
        // matched above. This handles TOTP, Duo, custom PAM challenges, etc.
        if let line = genericChallengeLine(in: buffer) {
            return .keyboardInteractive(prompt: line)
        }

        return nil
    }

    // MARK: - Pattern helpers

    private static func firstTimeHostKey(in buffer: String) -> SFTPPrompt? {
        // Looking for the canonical OpenSSH text:
        //   The authenticity of host 'HOST (ADDR)' can't be established.
        //   KEYTYPE key fingerprint is FINGERPRINT.
        //   This key is not known by any other names.
        //   Are you sure you want to continue connecting (yes/no/[fingerprint])?
        guard buffer.contains("authenticity of host") else { return nil }
        guard buffer.contains("Are you sure you want to continue connecting") else { return nil }

        // Host
        let hostRange = buffer.range(of: "host '([^']+)'", options: .regularExpression)
        var host = "remote host"
        if let hr = hostRange {
            let inner = buffer[hr]
            let s = inner.replacingOccurrences(of: "host '", with: "")
            host = s.replacingOccurrences(of: "'", with: "")
        }

        // Key type and fingerprint
        var keyType = "?"
        var fingerprint = "?"
        if let r = buffer.range(of: #"([A-Z0-9]+) key fingerprint is (\S+)"#, options: .regularExpression) {
            let line = String(buffer[r])
            let parts = line.split(separator: " ")
            // Expected: ["ED25519", "key", "fingerprint", "is", "SHA256:..."]
            if parts.count >= 5 {
                keyType = String(parts[0])
                fingerprint = String(parts[4])
            }
        }

        return .hostKey(host: host, keyType: keyType, fingerprint: fingerprint)
    }

    private static func passphraseKeyPath(in buffer: String) -> String? {
        // "Enter passphrase for key '/Users/me/.ssh/id_ed25519':"
        guard let r = buffer.range(of: #"Enter passphrase for key '([^']+)':"#, options: .regularExpression) else {
            return nil
        }
        let chunk = String(buffer[r])
        if let q1 = chunk.firstIndex(of: "'"),
           let q2 = chunk[chunk.index(after: q1)...].firstIndex(of: "'") {
            return String(chunk[chunk.index(after: q1)..<q2])
        }
        return nil
    }

    private static func passwordLabel(in buffer: String) -> String? {
        // "alice@host.example.com's password: " or just "Password: "
        // We match on the last colon-prompt that ends the buffer.
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":") else { return nil }
        if let r = trimmed.range(of: #"([^\s]+@[^\s]+)'s password:$"#, options: .regularExpression) {
            return String(trimmed[r]).replacingOccurrences(of: "'s password:", with: "")
        }
        if trimmed.lowercased().hasSuffix("password:") {
            return "Password"
        }
        return nil
    }

    private static func genericChallengeLine(in buffer: String) -> String? {
        // Only fire when the trimmed buffer ends with ":" — i.e., sftp/ssh is waiting for input.
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(":") else { return nil }
        // Extract the last non-empty line as the label.
        let lastLine = trimmed
            .components(separatedBy: CharacterSet.newlines)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
            ?? trimmed
        return lastLine
    }

    private static func extractMismatchHost(_ buffer: String) -> String? {
        // Looks like: "Host key verification failed.\nHost: host.example.com"
        // But OpenSSH usually says: "Add correct host key in /Users/.../known_hosts to get rid of this message."
        // We pull the host from "Offending ... key in /path/to/known_hosts:LINE" line, or fall back to the
        // address that appears earlier in the same warning block.
        // For simplicity we don't try to extract — caller passes the endpoint host separately.
        nil
    }
}
