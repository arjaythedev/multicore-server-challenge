package conduit;

import java.util.List;
import org.ethelred.kiwiproc.annotation.DAO;
import org.ethelred.kiwiproc.annotation.SqlQuery;

@DAO
public interface TagDao {

    @SqlQuery("SELECT name FROM tags ORDER BY name")
    List<String> allNames();
}
