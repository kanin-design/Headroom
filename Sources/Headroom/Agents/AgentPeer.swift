import Darwin
import Foundation
import Security

/// Who an agent says it is, and which program is really on the other end. The name is the agent's own word. The program
/// and who signed it are read from the system, so they can't be made up.
struct AgentIdentity: Codable, Hashable {
    /// What the agent calls itself.
    var name: String
    /// The program that started it: an app, or a command-line tool by its path.
    var program: String
    /// Who signed that program, when its signature holds.
    var signer: String?

    /// What an approval is remembered by. A program that moves or changes hands is a different agent.
    var key: String { [name, program, signer ?? ""].joined(separator: "\n") }

    /// The program as you'd say it: Claude for `/Applications/Claude.app`, the file's name for a tool.
    var programName: String {
        let last = (program as NSString).lastPathComponent
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}

/// What the system knows about the process at the other end of a connection.
enum AgentPeer {
    /// The process that opened this connection.
    static func pid(ofSocket fd: Int32) -> pid_t? {
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else { return nil }
        return pid
    }

    /// The file a process is running.
    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// The process that started this one.
    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// The app a file is part of, or the file itself.
    static func program(ofPath path: String) -> String {
        guard let end = path.range(of: ".app/") else { return path }
        return String(path[..<end.lowerBound]) + ".app"
    }

    /// Programs that only pass a command on: the one that matters is the one that started them.
    private static let goBetweens: Set<String> = ["sh", "bash", "zsh", "dash", "env", "nohup"]

    /// The program behind a connection, and the process to ask about its signature. Headroom's own helper only relays, so
    /// the agent is whatever started it; anything else that connects is the agent itself.
    static func program(behind peer: pid_t, helper: String?) -> (pid: pid_t, path: String)? {
        guard let own = path(of: peer) else { return nil }
        guard let helper, own == helper else { return (peer, program(ofPath: own)) }
        var at = peer
        for _ in 0..<8 {
            guard let above = parent(of: at), let file = path(of: above) else { break }
            at = above
            if file == helper || goBetweens.contains((file as NSString).lastPathComponent) { continue }
            return (above, program(ofPath: file))
        }
        return nil
    }

    /// Who signed the program a process is running, if its signature holds. An ad-hoc signature names nobody.
    static func signer(of pid: pid_t) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &onDisk) == errSecSuccess, let onDisk else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let facts = info as? [String: Any],
              let certificates = facts[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }

    /// Everything about the agent behind a connection that doesn't come from the agent: the program, and who signed it.
    /// Reading a signature takes a moment for a large app, so this is for the connection's own thread.
    static func origin(ofSocket fd: Int32, helper: String?) -> (program: String, signer: String?) {
        guard let peer = pid(ofSocket: fd), let behind = program(behind: peer, helper: helper) else { return ("Unknown program", nil) }
        return (behind.path, signer(of: behind.pid))
    }
}
