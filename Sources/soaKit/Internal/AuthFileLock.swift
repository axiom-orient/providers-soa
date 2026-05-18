import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct ExclusiveAuthFileLock: @unchecked Sendable {
    private let fileDescriptor: Int32

    static func acquire(forAuthPath authPath: String) throws -> ExclusiveAuthFileLock {
        let lockPath = authPath + ".soa.refresh.lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else {
            throw SoaError.authRefreshFailed(
                "could not open refresh lock at \(lockPath): \(currentPOSIXErrorDescription())",
                path: authPath
            )
        }
        #if os(Linux)
        _ = Glibc.fchmod(descriptor, mode_t(0o600))
        #else
        _ = Darwin.fchmod(descriptor, mode_t(0o600))
        #endif
        guard flock(descriptor, LOCK_EX) == 0 else {
            let message = currentPOSIXErrorDescription()
            _ = close(descriptor)
            throw SoaError.authRefreshFailed(
                "could not acquire refresh lock at \(lockPath): \(message)",
                path: authPath
            )
        }
        return ExclusiveAuthFileLock(fileDescriptor: descriptor)
    }

    func release() {
        _ = flock(fileDescriptor, LOCK_UN)
        _ = close(fileDescriptor)
    }
}

private func currentPOSIXErrorDescription() -> String {
    let code = errno
    guard let value = strerror(code) else {
        return "errno=\(code)"
    }
    return String(cString: value)
}
