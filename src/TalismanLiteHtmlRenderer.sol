// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DynamicBufferLib} from "solady/utils/DynamicBufferLib.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Camera, FillMode, LightSettings, Material, RenderSettings, Triangle} from "./TalismanStructs.sol";

/// @title TalismanLiteHtmlRenderer
/// @notice Pure renderer that emits a self-contained interactive HTML viewer driven by
///         a hand-built JS renderer - no CDN, no three.js. It draws with WebGL when
///         available and falls back to Canvas2D, reproducing the SVG renderer's
///         projection, painter's-algorithm depth sort, viewport mapping, and per-frame
///         world-space lighting. Drag and auto-rotate semantics match
///         TalismanHtmlRenderer.
/// @dev At rotQ=identity the output matches the SVG renderer's baked frame-zero shading
///      exactly; under rotation, faces relight as their orientation relative to the
///      world-fixed light changes (light and camera stay put). Debug overlay (FPS,
///      polygon counts, backend, cull state) toggles with `D`; while overlay is open,
///      `B` swaps WebGL <-> Canvas2D and `Q` toggles backface culling (default on).
contract TalismanLiteHtmlRenderer {
    using DynamicBufferLib for DynamicBufferLib.DynamicBuffer;

    struct LiteHtmlRenderSettings {
        bool orbitControls;
        bool autoRotate;
        /// @dev When true, debug overlay (FPS, poly counts, backend) is visible on load.
        ///      `D` toggles overlay at runtime regardless. `B` swaps WebGL<->2D while
        ///      overlay is visible.
        bool debug;
    }

    /**
     * @notice Renders a self-contained interactive HTML viewer for a mesh, with the
     * hand-built WebGL/Canvas2D JS renderer inlined.
     * @param triangles The mesh faces to draw, each referencing a material by id.
     * @param camera The camera position, look-at target, and field of view.
     * @param materials The material palette; each face's color is looked up by id.
     * @param settings The render settings (fill mode and backface cull mode).
     * @param light The lighting parameters (direction, ambient, reflectance, emissive, mesh center).
     * @param liteSettings The viewer settings (orbit controls, auto-rotate, debug overlay).
     * @return The complete HTML document as a string.
     */
    function renderHtml(
        Triangle[] memory triangles,
        Camera memory camera,
        Material[] memory materials,
        RenderSettings memory settings,
        LightSettings memory light,
        LiteHtmlRenderSettings memory liteSettings
    ) public pure returns (string memory) {
        bool wireframe = settings.fillMode == uint8(FillMode.Wireframe);
        return string.concat(
            "<!DOCTYPE html><html><head><style>html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden}#lite-container{width:100%;height:100%;cursor:grab}canvas{display:block;width:100%;height:100%}</style></head>",
            "<body><div id='lite-container'></div>",
            "<script>(function(){",
            _emitVertexData(triangles, materials),
            _emitCameraConsts(camera),
            _emitLightConsts(light),
            "var BG=[0,0,0];var BGA=1;",
            _emitMode(
                wireframe, liteSettings.orbitControls, liteSettings.autoRotate, liteSettings.debug, settings.cullMode
            ),
            _RENDERER_JS,
            "})();</script></body></html>"
        );
    }

    function _emitVertexData(Triangle[] memory triangles, Material[] memory materials)
        internal
        pure
        returns (string memory)
    {
        DynamicBufferLib.DynamicBuffer memory buf;
        buf.reserve(triangles.length * (9 * 21 + 9) + materials.length * 9 + 300);

        buf.p("var V=[");
        for (uint256 i = 0; i < triangles.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(LibString.toString(triangles[i].p1.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p1.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p1.z)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p2.z)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.x)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.y)));
            buf.p(",");
            buf.p(bytes(LibString.toString(triangles[i].p3.z)));
        }
        buf.p("].map(function(c){return c/1e18;});");

        buf.p("var M=[");
        for (uint256 i = 0; i < triangles.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(LibString.toString(uint256(triangles[i].materialId))));
        }
        buf.p("];");

        buf.p("var C=[");
        for (uint256 i = 0; i < materials.length; i++) {
            if (i > 0) {
                buf.p(",");
            }
            buf.p(bytes(_colorToCssHex(materials[i].color)));
        }
        buf.p("];");
        return buf.s();
    }

    function _emitCameraConsts(Camera memory camera) internal pure returns (string memory) {
        return string.concat(
            "var CP=[",
            LibString.toString(camera.location.x),
            "/1e18,",
            LibString.toString(camera.location.y),
            "/1e18,",
            LibString.toString(camera.location.z),
            "/1e18];",
            "var CT=[",
            LibString.toString(camera.lookAt.x),
            "/1e18,",
            LibString.toString(camera.lookAt.y),
            "/1e18,",
            LibString.toString(camera.lookAt.z),
            "/1e18];",
            "var FOV=",
            LibString.toString(camera.fieldOfView),
            "/1e18;"
        );
    }

    /// @dev Emits world-space light direction + ambient coefficient. JS recomputes
    ///      Lambertian per face per frame using the same formula as
    ///      TalismanSvgRenderer.computeLitMaterials so frame-zero output matches the
    ///      static SVG bake exactly. When light.enabled == false, JS skips the lighting
    ///      step and uses raw material colors.
    function _emitLightConsts(LightSettings memory light) internal pure returns (string memory) {
        return string.concat(
            "var LE=",
            light.enabled ? "1" : "0",
            ";var LD=[",
            LibString.toString(light.direction.x),
            "/1e18,",
            LibString.toString(light.direction.y),
            "/1e18,",
            LibString.toString(light.direction.z),
            "/1e18];",
            "var AMB=",
            LibString.toString(light.ambient),
            "/1e18;",
            "var REF=",
            LibString.toString(light.reflectance),
            "/1e18;",
            "var EMI=",
            LibString.toString(light.emissive),
            "/1e18;",
            "var MC=[",
            LibString.toString(light.meshCenter.x),
            "/1e18,",
            LibString.toString(light.meshCenter.y),
            "/1e18,",
            LibString.toString(light.meshCenter.z),
            "/1e18];"
        );
    }

    function _emitMode(bool wireframe, bool orbit, bool autoRotate, bool debug, uint8 cullMode)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "var WF=",
            wireframe ? "1" : "0",
            ";var OC=",
            orbit ? "1" : "0",
            ";var AR=",
            autoRotate ? "1" : "0",
            ";var DBG=",
            debug ? "1" : "0",
            ";var CL=",
            LibString.toString(uint256(cullMode)),
            ";"
        );
    }

    /// @dev Hand-built renderer: vec/quat math, camera transform mirroring
    ///      TalismanSvgRenderer.transformTri (with X-flip), perspective projection
    ///      mirroring projectPoint, painter's algorithm sort, per-frame Lambertian
    ///      lighting on rotated world-space normals against a world-fixed light dir
    ///      (mirrors computeLitMaterials), and WebGL+Canvas2D backends. Drag uses a
    ///      Shoemake arcball: cursor maps to a unit hemisphere, the rotation each frame
    ///      is the single shortest-arc quaternion from the gesture's start point to the
    ///      current point, applied to the rotation captured at mousedown - so each
    ///      stroke is path-reversible (returning the cursor to its start restores the
    ///      original orientation) and the model "follows the finger" regardless of the
    ///      camera tilt. Auto-rotate stays at 0.005 rad/frame about world up with a 5 s
    ///      idle resume. Debug overlay (FPS, polys, backend, cull) toggles
    ///      with `D`; while overlay is open, `B` swaps WebGL<->Canvas2D and `Q`
    ///      toggles backface culling (default on).
    string internal constant _RENDERER_JS = "var box=document.getElementById('lite-container');"
        "box.style.position=box.style.position||'relative';box.tabIndex=0;"
        "function vS(a,b){return [a[0]-b[0],a[1]-b[1],a[2]-b[2]];}"
        "function vN(a){var L=Math.hypot(a[0],a[1],a[2])||1;return [a[0]/L,a[1]/L,a[2]/L];}"
        "function vC(a,b){return [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];}"
        "function vD(a,b){return a[0]*b[0]+a[1]*b[1]+a[2]*b[2];}"
        "function qAA(ax,th){var s=Math.sin(th/2);return [ax[0]*s,ax[1]*s,ax[2]*s,Math.cos(th/2)];}"
        "function qM(a,b){return [a[3]*b[0]+a[0]*b[3]+a[1]*b[2]-a[2]*b[1],a[3]*b[1]-a[0]*b[2]+a[1]*b[3]+a[2]*b[0],a[3]*b[2]+a[0]*b[1]-a[1]*b[0]+a[2]*b[3],a[3]*b[3]-a[0]*b[0]-a[1]*b[1]-a[2]*b[2]];}"
        "function qR(q,v){var x=q[0],y=q[1],z=q[2],w=q[3];var ix=w*v[0]+y*v[2]-z*v[1],iy=w*v[1]+z*v[0]-x*v[2],iz=w*v[2]+x*v[1]-y*v[0],iw=-x*v[0]-y*v[1]-z*v[2];return [ix*w+iw*-x+iy*-z-iz*-y,iy*w+iw*-y+iz*-x-ix*-z,iz*w+iw*-z+ix*-y-iy*-x];}"
        "var f=vN(vS(CT,CP));var up=[0,1,0];var rgt=vN(vC(up,f));var u=vC(f,rgt);"
        "function applyLA(p){var x=p[0]*rgt[0]+p[1]*rgt[1]+p[2]*rgt[2];var y=p[0]*u[0]+p[1]*u[1]+p[2]*u[2];var z=p[0]*f[0]+p[1]*f[1]+p[2]*f[2];return [-x,y,z];}"
        "var focal=1/Math.tan(FOV*Math.PI/180/2);" "var W=512,H=512,S=256;"
        "function proj(p){var z=p[2]<0.1?0.1:p[2];return [W/2+focal*p[0]/z*S,H/2-focal*p[1]/z*S];}"
        "var LDN=LE?vN(LD):[0,0,0];var hasMC=MC[0]!=0||MC[1]!=0||MC[2]!=0;"
        "function shade(p1w,p2w,p3w,baseHex){if(!LE)return baseHex;" "var n=vN(vC(vS(p2w,p1w),vS(p3w,p1w)));"
        "if(hasMC){var ctr=[(p1w[0]+p2w[0]+p3w[0])/3,(p1w[1]+p2w[1]+p3w[1])/3,(p1w[2]+p2w[2]+p3w[2])/3];var to=[ctr[0]-MC[0],ctr[1]-MC[1],ctr[2]-MC[2]];if(vD(n,to)<0){n=[-n[0],-n[1],-n[2]];}}"
        "var d=-vD(n,LDN);"
        "if(d<=0&&hasMC){var ctr2=[(p1w[0]+p2w[0]+p3w[0])/3,(p1w[1]+p2w[1]+p3w[1])/3,(p1w[2]+p2w[2]+p3w[2])/3];var to2=[ctr2[0]-MC[0],ctr2[1]-MC[1],ctr2[2]-MC[2]];if(to2[0]*to2[0]+to2[1]*to2[1]+to2[2]*to2[2]>0){d=-vD(vN(to2),LDN);}}"
        "if(d<0)d=0;" "var br=EMI+REF*(AMB+d*(1-AMB));if(br>1)br=1;if(br<0)br=0;"
        "var nC=parseInt(baseHex.slice(1),16);var r=Math.floor(((nC>>16)&255)*br);var g=Math.floor(((nC>>8)&255)*br);var b=Math.floor((nC&255)*br);"
        "if(r>255)r=255;if(g>255)g=255;if(b>255)b=255;"
        "var hx=((r<<16)|(g<<8)|b).toString(16);while(hx.length<6)hx='0'+hx;return '#'+hx;}"
        "var rotQ=[0,0,0,1];var N=V.length/9;var CO=1;" "var stats={fps:0,total:N,front:0,lastT:0,dts:[]};"
        "function buildFrame(){var wV=new Array(N*3);var camV=new Array(N*3);"
        "for(var i=0;i<N;i++){for(var k=0;k<3;k++){var b=i*9+k*3;var v=[V[b],V[b+1],V[b+2]];v=qR(rotQ,v);wV[i*3+k]=v;camV[i*3+k]=applyLA([v[0]-CP[0],v[1]-CP[1],v[2]-CP[2]]);}}"
        "var idx=new Array(N);for(var j=0;j<N;j++)idx[j]=j;"
        "for(var s=1;s<N;s++){var key=idx[s];var d=(camV[key*3][2]+camV[key*3+1][2]+camV[key*3+2][2])/3;var t=s-1;while(t>=0){var dt=(camV[idx[t]*3][2]+camV[idx[t]*3+1][2]+camV[idx[t]*3+2][2])/3;if(dt>=d)break;idx[t+1]=idx[t];t--;}idx[t+1]=key;}"
        "var out=new Array(N);var fc=0;for(var p=0;p<N;p++){var ti=idx[p];var s2d=[proj(camV[ti*3]),proj(camV[ti*3+1]),proj(camV[ti*3+2])];var w2=(s2d[1][0]-s2d[0][0])*(s2d[2][1]-s2d[0][1])-(s2d[1][1]-s2d[0][1])*(s2d[2][0]-s2d[0][0]);if(w2<0)fc++;if(CO&&((CL===1&&w2>=0)||(CL===2&&w2<0))){out[p]=null;continue;}var base=C[M[ti]];var col=shade(wV[ti*3],wV[ti*3+1],wV[ti*3+2],base);out[p]={s2d:s2d,col:col};}stats.front=fc;return out;}"
        "var cv,gl,ctx2d,prog,aPos,aCol,bufP,bufC;var forceMode=null;"
        "function setupBackend(){var oldCv=box.querySelector('canvas');if(oldCv){if(gl){var lx=gl.getExtension&&gl.getExtension('WEBGL_lose_context');if(lx)lx.loseContext();}box.removeChild(oldCv);}"
        "cv=document.createElement('canvas');W=box.clientWidth||512;H=box.clientHeight||512;S=Math.min(W,H)/2;cv.width=W;cv.height=H;box.appendChild(cv);gl=null;ctx2d=null;"
        "if(forceMode!=='2d'){try{gl=cv.getContext('webgl',{antialias:true,alpha:true})||cv.getContext('experimental-webgl',{antialias:true,alpha:true});}catch(e){}}"
        "if(gl){var vsh=gl.createShader(gl.VERTEX_SHADER);gl.shaderSource(vsh,'attribute vec2 a;attribute vec3 c;varying vec3 vc;void main(){vc=c;gl_Position=vec4(a,0.0,1.0);}');gl.compileShader(vsh);"
        "var fsh=gl.createShader(gl.FRAGMENT_SHADER);gl.shaderSource(fsh,'precision mediump float;varying vec3 vc;void main(){gl_FragColor=vec4(vc,1.0);}');gl.compileShader(fsh);"
        "prog=gl.createProgram();gl.attachShader(prog,vsh);gl.attachShader(prog,fsh);gl.linkProgram(prog);gl.useProgram(prog);"
        "aPos=gl.getAttribLocation(prog,'a');aCol=gl.getAttribLocation(prog,'c');"
        "bufP=gl.createBuffer();bufC=gl.createBuffer();gl.viewport(0,0,W,H);gl.disable(gl.DEPTH_TEST);}"
        "else{ctx2d=cv.getContext('2d');}}" "setupBackend();" "var ov=document.createElement('div');"
        "ov.style.cssText='position:absolute;top:6px;left:6px;background:rgba(0,0,0,0.7);color:#9ef79e;font:11px/1.45 ui-monospace,Menlo,monospace;padding:4px 7px;border-radius:3px;z-index:9;white-space:pre;pointer-events:none;display:'+(DBG?'block':'none')+';';"
        "box.appendChild(ov);"
        "function ovUpdate(){if(ov.style.display==='none')return;var be=gl?'WebGL':'Canvas2D';var fc=forceMode?' [forced]':'';var ft=stats.dts.length?stats.dts[stats.dts.length-1].toFixed(2):'-';ov.textContent='FPS    '+stats.fps.toFixed(1)+'\\nTris   '+stats.total+' (vis '+stats.front+')\\nMode   '+be+fc+'\\nCull   '+(CO?'on':'off')+'\\nFrame  '+ft+' ms\\n[D] toggle  [B] backend  [Q] cull';}"
        "function hexF(h){var n=parseInt(h.slice(1),16);return [((n>>16)&255)/255,((n>>8)&255)/255,(n&255)/255];}"
        "function drawGl(frame){var pn=N*(WF?6:3);var pa=new Float32Array(pn*2);var ca=new Float32Array(pn*3);var w=0;for(var i=0;i<N;i++){var t=frame[i];if(!t)continue;var rgb=hexF(t.col);if(WF){var p1=t.s2d[0],p2=t.s2d[1],p3=t.s2d[2];var pairs=[p1,p2,p2,p3,p3,p1];for(var q=0;q<6;q++){pa[w*2]=pairs[q][0]*2/W-1;pa[w*2+1]=1-pairs[q][1]*2/H;ca[w*3]=rgb[0];ca[w*3+1]=rgb[1];ca[w*3+2]=rgb[2];w++;}}else{for(var k=0;k<3;k++){pa[w*2]=t.s2d[k][0]*2/W-1;pa[w*2+1]=1-t.s2d[k][1]*2/H;ca[w*3]=rgb[0];ca[w*3+1]=rgb[1];ca[w*3+2]=rgb[2];w++;}}}"
        "gl.clearColor(BG[0],BG[1],BG[2],BGA);gl.clear(gl.COLOR_BUFFER_BIT);"
        "gl.bindBuffer(gl.ARRAY_BUFFER,bufP);gl.bufferData(gl.ARRAY_BUFFER,pa,gl.DYNAMIC_DRAW);gl.enableVertexAttribArray(aPos);gl.vertexAttribPointer(aPos,2,gl.FLOAT,false,0,0);"
        "gl.bindBuffer(gl.ARRAY_BUFFER,bufC);gl.bufferData(gl.ARRAY_BUFFER,ca,gl.DYNAMIC_DRAW);gl.enableVertexAttribArray(aCol);gl.vertexAttribPointer(aCol,3,gl.FLOAT,false,0,0);"
        "gl.drawArrays(WF?gl.LINES:gl.TRIANGLES,0,w);}"
        "function draw2d(frame){ctx2d.clearRect(0,0,W,H);if(BGA>0){ctx2d.fillStyle='rgba('+Math.round(BG[0]*255)+','+Math.round(BG[1]*255)+','+Math.round(BG[2]*255)+','+BGA+')';ctx2d.fillRect(0,0,W,H);}for(var i=0;i<N;i++){var t=frame[i];if(!t)continue;ctx2d.beginPath();ctx2d.moveTo(t.s2d[0][0],t.s2d[0][1]);ctx2d.lineTo(t.s2d[1][0],t.s2d[1][1]);ctx2d.lineTo(t.s2d[2][0],t.s2d[2][1]);ctx2d.closePath();if(WF){ctx2d.strokeStyle=t.col;ctx2d.lineWidth=1;ctx2d.stroke();}else{ctx2d.fillStyle=t.col;ctx2d.fill();}}}"
        "function render(){var t=performance.now();if(stats.lastT){var dt=t-stats.lastT;stats.dts.push(dt);if(stats.dts.length>30)stats.dts.shift();var sum=0;for(var i=0;i<stats.dts.length;i++)sum+=stats.dts[i];stats.fps=stats.dts.length/(sum/1000);}stats.lastT=t;"
        "var frame=buildFrame();if(gl)drawGl(frame);else draw2d(frame);ovUpdate();}render();"
        "if(OC){var down=false,startQ=null,p0=null;"
        "function abV(e){var r=box.getBoundingClientRect();var x=(e.clientX-r.left)/r.width*2-1;var y=(e.clientY-r.top)/r.height*2-1;var d=x*x+y*y;if(d>1){var L=1/Math.sqrt(d);return [x*L,-y*L,0];}return [x,-y,Math.sqrt(1-d)];}"
        "box.addEventListener('mousedown',function(e){down=true;p0=abV(e);startQ=rotQ.slice();box.style.cursor='grabbing';});"
        "box.addEventListener('mousemove',function(e){if(!down)return;var p1=abV(e);var cs=vC(p0,p1);var dt=vD(p0,p1);var aw=[cs[0]*rgt[0]+cs[1]*u[0]-cs[2]*f[0],cs[0]*rgt[1]+cs[1]*u[1]-cs[2]*f[1],cs[0]*rgt[2]+cs[1]*u[2]-cs[2]*f[2]];rotQ=qM([aw[0],aw[1],aw[2],dt],startQ);render();});"
        "box.addEventListener('mouseup',function(){down=false;box.style.cursor='grab';});"
        "box.addEventListener('mouseleave',function(){down=false;});}"
        "if(AR){var aOn=true,aT=null;function ar(){if(!aOn)return;requestAnimationFrame(ar);rotQ=qM(qAA([0,1,0],0.005),rotQ);render();}"
        "function arS(){clearTimeout(aT);aT=setTimeout(function(){if(!aOn){aOn=true;ar();}},5000);}"
        "box.addEventListener('mousedown',function(){aOn=false;clearTimeout(aT);});box.addEventListener('mouseup',arS);box.addEventListener('mouseleave',arS);ar();}"
        "window.addEventListener('resize',function(){if(!cv)return;W=box.clientWidth||512;H=box.clientHeight||512;S=Math.min(W,H)/2;cv.width=W;cv.height=H;if(gl)gl.viewport(0,0,W,H);render();});"
        "window.addEventListener('keydown',function(e){if(e.target&&(e.target.tagName==='INPUT'||e.target.tagName==='TEXTAREA'||e.target.isContentEditable))return;if(e.ctrlKey||e.metaKey||e.altKey)return;if(e.key==='d'||e.key==='D'){ov.style.display=(ov.style.display==='none')?'block':'none';if(ov.style.display==='block')ovUpdate();e.preventDefault();}else if((e.key==='b'||e.key==='B')&&ov.style.display==='block'){forceMode=gl?'2d':null;setupBackend();render();e.preventDefault();}else if((e.key==='q'||e.key==='Q')&&ov.style.display==='block'){CO=CO?0:1;render();e.preventDefault();}});";

    function _colorToCssHex(uint32 color) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory result = new bytes(9);
        result[0] = "'";
        result[1] = "#";
        for (uint256 i = 0; i < 6; i++) {
            uint256 nibble = (color >> ((5 - i) * 4)) & 0xF;
            result[2 + i] = hexChars[nibble];
        }
        result[8] = "'";
        return string(result);
    }
}
