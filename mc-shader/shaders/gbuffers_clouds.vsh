#version 120
varying vec2 texcoord;
varying vec3 viewPos;
void main() {
    gl_Position = ftransform();
    texcoord = (gl_MultiTexCoord0).xy;
    viewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
}
