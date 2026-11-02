import Foundation

/// Where the running app really is.
///
/// Gatekeeper runs a quarantined app that wasn't moved in Finder from a
/// read-only copy at a random path, which goes away when the app quits. That
/// can happen in /Applications too, so the `headroom` link and updates go to
/// the copy the user actually has.
public enum InstalledApp {
    public static let url: URL = {
        let running = Bundle.main.bundleURL
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return running }
        typealias Original = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let original = unsafeBitCast(symbol, to: Original.self)
        return original(running as CFURL, nil)?.takeRetainedValue() as URL? ?? running
    }()
}
