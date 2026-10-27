package example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class AppTest {
  @Test
  void welcomes() {
    assertEquals("hello app", new App().welcome());
  }
}
