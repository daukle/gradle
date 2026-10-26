do
  local toolchain = daukle.config.toolchains and daukle.config.toolchains.gradle

  do
    local owner = toolchain
    owner["configurations"] = owner["configurations"] or {}
    owner = owner["configurations"]
    local pins = owner["checkstyle"] or {}

    pins[#pins + 1] = {
      url = "https://repo1.maven.org/maven2/com/puppycrawl/tools/checkstyle/10.11.0/checkstyle-10.11.0.jar",
      sha256 = "c90904eb2a36feea9d74ec16f115f58acdbc114588f9f40fb80e8ce3dca1a8c7",
      as = "checkstyle 10.11.0",
    }

    owner["checkstyle"] = pins
  end
end
