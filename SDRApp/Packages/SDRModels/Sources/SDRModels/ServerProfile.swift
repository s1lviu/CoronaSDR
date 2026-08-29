import Foundation
import SwiftData

@Model
public final class ServerProfile {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var protocolTypeRaw: String
    @Relationship(deleteRule: .cascade)
    public var sampleProfiles: [SampleProfile]
    public var connectionTimeoutMs: Int
    public var reconnectPolicyRaw: String

    public var protocolType: SDRProtocol {
        get { SDRProtocol(rawValue: protocolTypeRaw) ?? .rtlTcp }
        set { protocolTypeRaw = newValue.rawValue }
    }

    public var reconnectPolicy: ReconnectPolicy {
        get { ReconnectPolicy(rawValue: reconnectPolicyRaw) ?? .exponentialBackoff }
        set { reconnectPolicyRaw = newValue.rawValue }
    }

    public init(
        name: String,
        host: String,
        port: Int = 1234,
        protocolType: SDRProtocol = .rtlTcp,
        connectionTimeoutMs: Int = 5000,
        reconnectPolicy: ReconnectPolicy = .exponentialBackoff
    ) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.port = port
        self.protocolTypeRaw = protocolType.rawValue
        self.sampleProfiles = SampleProfile.defaults()
        self.connectionTimeoutMs = connectionTimeoutMs
        self.reconnectPolicyRaw = reconnectPolicy.rawValue
    }
}
