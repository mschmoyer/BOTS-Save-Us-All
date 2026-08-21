local S = {}
function S:enter()
  local n, v = love.graphics.getRendererInfo()
  print("RENDERER", n, v)
  print("shaders", love.graphics.getSupported and "yes" or "no")
  local ok, sh = pcall(love.graphics.newShader, [[
#ifdef VERTEX
attribute vec4 TreeData;
attribute vec2 BlobOff;
uniform vec4 uT;
varying vec3 vShade;
varying float vRim;
vec4 position(mat4 tpm, vec4 vp){
  float h = TreeData.x;
  float s = mix(uT.x, uT.y, TreeData.y);
  vp.x += s*h*h;
  vec2 n = BlobOff; float nl = length(n);
  float l = nl > 0.0001 ? dot(n/nl, vec2(0.6,-0.8)) : 0.0;
  vShade = vec3(1.0 + l*0.4);
  vRim = smoothstep(0.5,1.0,l)*TreeData.w;
  return tpm * vp;
}
#endif
#ifdef PIXEL
varying vec3 vShade; varying float vRim;
vec4 effect(vec4 color, Image t, vec2 tc, vec2 sc){
  return vec4(color.rgb*vShade + vec3(vRim*0.2), color.a);
}
#endif
]])
  print("SHADER OK?", ok, tostring(sh):sub(1,200))
  local ok2, m = pcall(love.graphics.newMesh, {
    {"VertexPosition","float",2},{"VertexColor","byte",4},
    {"TreeData","float",4},{"BlobOff","float",2},
  }, {
    {0,0, 255,0,0,255, 0,0,2,0, 0,0},
    {50,0, 0,255,0,255, 0,0,2,0, 1,0},
    {25,-50, 0,0,255,255, 1,1,2,1, 0,-1},
  }, "triangles", "static")
  print("MESH OK?", ok2, tostring(m):sub(1,120))
  self.sh, self.m = ok and sh or nil, ok2 and m or nil
end
function S:update(dt) end
function S:draw()
  love.graphics.clear(0.1,0.1,0.12)
  if self.sh and self.m then
    love.graphics.setShader(self.sh)
    self.sh:send("uT", {0.2,0.1,0,0})
    love.graphics.draw(self.m, 400, 400, 0, 3, 3)
    love.graphics.setShader()
  end
  love.graphics.print("probe", 20, 20)
end
return S
