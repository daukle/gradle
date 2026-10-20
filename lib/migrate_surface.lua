--- The rows of `GRADLE-SURFACE.md` a migration blocker points at, and the
--- blocker itself, in core's shape: { construct, where, why, surface? }.
local migrate_surface = {}

local SURFACE = "GRADLE-SURFACE.md: "

migrate_surface.BOUNDARY_ROW = SURFACE .. 'The boundary: what "100% of Gradle" does not include'
migrate_surface.SETTINGS_PLUGINS_ROW = SURFACE .. "1. The settings file, a settings-level `plugins {}` block"
migrate_surface.CONFIGURATIONS_ROW = SURFACE .. "2. Dependency configurations"
migrate_surface.LAYOUT_ROW = SURFACE .. "3. The `java` extension and source layout"
migrate_surface.PACKAGING_ROW = SURFACE .. "4. Packaging and publishing"
migrate_surface.TESTING_ROW = SURFACE .. "5. Testing"
migrate_surface.UNCOVERED_ROW = SURFACE .. "6. What this file does NOT yet cover, said plainly"

function migrate_surface.blocker(construct, where, why, surface)
  return { construct = construct, where = where, why = why, surface = surface }
end

return migrate_surface
