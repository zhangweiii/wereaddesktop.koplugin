-- Single source of truth for the plugin version. _meta.lua exposes it
-- to KOReader's plugin manager; updater.lua compares it against the
-- latest GitHub release. (Deliberately prefixed: "version" in the
-- shared package.path would risk colliding with other plugins.)
return "0.2.0-alpha.3"
