package example;

import com.google.gson.Gson;
import org.apache.commons.lang3.StringUtils;

public class Ledger {
    public static String title(String name) {
        return new Gson().toJson(StringUtils.capitalize(name));
    }
}
