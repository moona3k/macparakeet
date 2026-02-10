import Foundation

public protocol LicenseAPI: Sendable {
    func activate(licenseKey: String, instanceName: String) async throws -> LicenseActivation
    func validate(licenseKey: String, instanceID: String?) async throws -> LicenseValidation
    func deactivate(licenseKey: String, instanceID: String) async throws
}

public struct LicenseActivation: Sendable {
    public let licenseKey: String
    public let instanceID: String
    public let variantID: Int?
}

public struct LicenseValidation: Sendable {
    public let valid: Bool
    public let variantID: Int?
}

public final class LemonSqueezyLicenseAPI: LicenseAPI {
    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://api.lemonsqueezy.com/v1")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func activate(licenseKey: String, instanceName: String) async throws -> LicenseActivation {
        let url = baseURL.appendingPathComponent("licenses/activate")
        let body = form([
            "license_key": licenseKey,
            "instance_name": instanceName,
        ])
        let data = try await post(url: url, body: body)
        let resp = try JSONDecoder().decode(ActivateResponse.self, from: data)
        guard resp.activated == true else {
            throw EntitlementsError.activationFailed(resp.error ?? "Activation failed.")
        }
        guard let instanceID = resp.instance?.id else {
            throw EntitlementsError.activationFailed("Activation succeeded but no instance id was returned.")
        }
        return LicenseActivation(
            licenseKey: resp.licenseKey?.key ?? licenseKey,
            instanceID: instanceID,
            variantID: resp.meta?.variantID
        )
    }

    public func validate(licenseKey: String, instanceID: String?) async throws -> LicenseValidation {
        let url = baseURL.appendingPathComponent("licenses/validate")
        var fields: [String: String] = ["license_key": licenseKey]
        if let instanceID { fields["instance_id"] = instanceID }
        let data = try await post(url: url, body: form(fields))
        let resp = try JSONDecoder().decode(ValidateResponse.self, from: data)
        if let err = resp.error, !err.isEmpty {
            throw EntitlementsError.invalidLicense(err)
        }
        return LicenseValidation(valid: resp.valid == true, variantID: resp.meta?.variantID)
    }

    public func deactivate(licenseKey: String, instanceID: String) async throws {
        let url = baseURL.appendingPathComponent("licenses/deactivate")
        let data = try await post(url: url, body: form([
            "license_key": licenseKey,
            "instance_id": instanceID,
        ]))
        let resp = try JSONDecoder().decode(DeactivateResponse.self, from: data)
        guard resp.deactivated == true else {
            throw EntitlementsError.activationFailed(resp.error ?? "Deactivation failed.")
        }
    }

    // MARK: - Private

    private func post(url: URL, body: Data) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { return data }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw EntitlementsError.network("Licensing server error (\(http.statusCode)). \(snippet)")
        }
        return data
    }

    private func form(_ fields: [String: String]) -> Data {
        let pairs = fields
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
        return Data(pairs.utf8)
    }

    private func escape(_ s: String) -> String {
        // application/x-www-form-urlencoded is stricter than URLQueryAllowed.
        // Encode everything except unreserved characters (RFC 3986).
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

// MARK: - Response models (subset of Lemon Squeezy payloads)

private struct ActivateResponse: Decodable {
    let activated: Bool?
    let error: String?
    let licenseKey: LicenseKeyPayload?
    let instance: InstancePayload?
    let meta: MetaPayload?

    enum CodingKeys: String, CodingKey {
        case activated
        case error
        case licenseKey = "license_key"
        case instance
        case meta
    }
}

private struct ValidateResponse: Decodable {
    let valid: Bool?
    let error: String?
    let meta: MetaPayload?
}

private struct DeactivateResponse: Decodable {
    let deactivated: Bool?
    let error: String?
}

private struct LicenseKeyPayload: Decodable {
    let key: String?
}

private struct InstancePayload: Decodable {
    let id: String?
}

private struct MetaPayload: Decodable {
    let variantID: Int?

    enum CodingKeys: String, CodingKey {
        case variantID = "variant_id"
    }
}
