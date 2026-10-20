package example;

import com.google.gson.Gson;

public class Plain {
  public static String json(String text) {
    return new Gson().toJson(text);
  }
}
