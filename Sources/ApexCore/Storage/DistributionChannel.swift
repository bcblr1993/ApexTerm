import Foundation

public enum DistributionChannel: String, Sendable {
    case direct
    case appStore

    public static var current: Self {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ApexDistributionChannel") as? String else {
            return .direct
        }
        return Self(rawValue: value) ?? .direct
    }

    public static let appStoreURL = URL(string: "macappstore://itunes.apple.com/app/id6818216165")!
}
