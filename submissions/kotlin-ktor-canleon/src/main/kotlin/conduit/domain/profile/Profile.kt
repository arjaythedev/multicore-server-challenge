package conduit.domain.profile

/** A user as others see them; [following] is whether the viewer follows them. */
class Profile(val username: String, val bio: String?, val image: String?, val following: Boolean)
