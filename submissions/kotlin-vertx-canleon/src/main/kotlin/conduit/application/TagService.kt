package conduit.application

import conduit.domain.tag.TagRepository

class TagService(private val tagRepository: TagRepository) {
    suspend fun all(): List<String> {
        return tagRepository.all()
    }
}
