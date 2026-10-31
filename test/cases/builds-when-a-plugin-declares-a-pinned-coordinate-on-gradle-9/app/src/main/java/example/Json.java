package example;

import com.google.gson.Gson;

public final class Json {
  public static String of(Object value) {
    return new Gson().toJson(value);
  }
}
