import Fluent
import Vapor

/// Response object for the current user / register / login.
struct UserDTO: Content, Sendable {
    let email: String
    let token: String
    let username: String
    let bio: String?
    let image: String?

    enum CodingKeys: String, CodingKey {
        case email, token, username, bio, image
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(email, forKey: .email)
        try container.encode(token, forKey: .token)
        try container.encode(username, forKey: .username)
        if let bio {
            try container.encode(bio, forKey: .bio)
        } else {
            try container.encodeNil(forKey: .bio)
        }
        if let image {
            try container.encode(image, forKey: .image)
        } else {
            try container.encodeNil(forKey: .image)
        }
    }
}

struct UserResponse: Content, Sendable {
    let user: UserDTO
}

struct ProfileDTO: Content, Sendable {
    let username: String
    let bio: String?
    let image: String?
    let following: Bool

    enum CodingKeys: String, CodingKey {
        case username, bio, image, following
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        if let bio {
            try container.encode(bio, forKey: .bio)
        } else {
            try container.encodeNil(forKey: .bio)
        }
        if let image {
            try container.encode(image, forKey: .image)
        } else {
            try container.encodeNil(forKey: .image)
        }
        try container.encode(following, forKey: .following)
    }
}

struct ProfileResponse: Content, Sendable {
    let profile: ProfileDTO
}

extension User {
    func toDTO(token: String) throws -> UserDTO {
        UserDTO(
            email: self.email,
            token: token,
            username: self.username,
            bio: self.bio,
            image: self.image
        )
    }

    func toProfile(following: Bool) -> ProfileDTO {
        ProfileDTO(
            username: self.username,
            bio: self.bio,
            image: self.image,
            following: following
        )
    }
}
