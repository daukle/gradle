package alpha;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class AlphaTest {
  @Test
  void namesItself() {
    assertEquals("alpha", Alpha.name());
  }

  @Test
  void namesItselfAgain() {
    assertEquals("alpha", Alpha.name());
  }
}
