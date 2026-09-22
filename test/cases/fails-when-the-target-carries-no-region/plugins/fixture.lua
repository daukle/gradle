daukle.plugin{ api = 1, uses = { "read", "parse" } }

daukle.source{
  name = "fixture",
  load = function(project, block)
    local file = block.path .. "/daukle.toml"
    return daukle.parse(daukle.read(file), file)
  end,
}
