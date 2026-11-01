package conduit;

import io.avaje.http.api.Controller;
import io.avaje.http.api.Get;

@Controller
class TagController implements ApiController {

    private final TagDao tags;

    TagController(TagDao tags) {
        this.tags = tags;
    }

    @Access(Access.Level.NONE)
    @Get("/api/tags")
    Dto.TagList tags() {
        return new Dto.TagList(tags.allNames());
    }
}
