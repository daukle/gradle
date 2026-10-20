package example;

import com.google.gson.Gson;

public class Cataloged {
    public static String json(String value) {
        return new Gson().toJson(value);
    }
}
