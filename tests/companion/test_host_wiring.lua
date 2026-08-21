return function(T)
  local function count(source, pattern)
    local total = 0
    for _ in source:gmatch(pattern) do total = total + 1 end
    return total
  end

  T.test("keeps the pinned 2.0.3 manifest and existing pipeline ownership", function()
    local manifest = T.read("manifest.json")
    local main = T.read("main.lua")
    T.truthy(manifest:find('"id": "DRAMALESS_SHAPE"', 1, true))
    T.truthy(manifest:find('"version": "2.0.3"', 1, true))
    T.truthy(manifest:find('"github": "artyrambles/DRAMALESS_SHAPE"', 1, true))
    T.truthy(main:find('mod.exports.version = "2.0.3"', 1, true))
    T.equal(count(main, 'render_pipelines:register%("voxel"'), 1)
    T.equal(count(main, "render_pipelines:register"), 2)
    T.truthy(main:find("mod.exports.voxel_companion", 1, true))
    T.falsy(main:find('render_pipelines:register("voxel_companion"', 1, true))
  end)

  T.test("inserts only certified callbacks in the official world pass order", function()
    local source = T.read("lib/VoxelScene.lua")
    local scene = assert(source:find("if not Voxel3D.beginScene", 1, true))
    local background = assert(source:find(
      'pcall(companion.dispatchRenderPhase, companion, "background")', 1, true))
    local terrain = assert(source:find("Voxel3D.draw(terrain", background, true))
    local opaque = assert(source:find(
      'pcall(companion.dispatchRenderPhase, companion, "opaque_after_terrain")', 1, true))
    local translucent = assert(source:find(
      'pcall(companion.dispatchRenderPhase, companion, "translucent_after_actors")', 1, true))
    local finish = assert(source:find("local canvas = Voxel3D.endScene()", translucent, true))
    T.truthy(scene < background)
    T.truthy(background < terrain)
    T.truthy(terrain < opaque)
    T.truthy(opaque < translucent)
    T.truthy(translucent < finish)
    T.falsy(source:find(
      'companion.dispatchRenderPhase, companion, "shadow_casters"', 1, true))
    T.falsy(source:find(
      'companion.dispatchRenderPhase, companion, "battle_opaque"', 1, true))
  end)

  T.test("keeps the legacy marker check read-only and outside scene source", function()
    local scene = T.read("lib/VoxelScene.lua")
    local host = T.read("lib/VoxelCompanionHost.lua")
    T.falsy(scene:find("Ceiling.draw", 1, true))
    T.truthy(host:find('Host.LEGACY_MARKERS', 1, true))
    T.truthy(host:find('"Ceiling.draw"', 1, true))
    T.truthy(host:find('read_source', 1, true))
    T.falsy(host:find("os.remove", 1, true))
    T.falsy(host:find("io.open", 1, true))
  end)

  T.test("packages the adapter and its public contract", function()
    local script = T.read("tools/package_mod.ps1")
    T.truthy(script:find('"assets", "data", "docs", "lib"', 1, true))
    T.truthy(script:find('"CHANGELOG.md", "LICENSE", "README.md", "main.lua", "manifest.json", "mod.card"', 1, true))
    T.truthy(T.read("docs/voxel-companion-api-v1.md"):find(
      "f14795b17e85d5d5baedcad63944065e446a4b0b", 1, true))
  end)
end
