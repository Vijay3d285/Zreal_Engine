#[compute]

#version 450

#VERSION_DEFINES

#include "_included.glsl"
#include "_included_2.glsl" // trailing comment on the second of two adjacent includes
// a comment that merely mentions #include "nothing.glsl" must not be chased
// the raw builder emits source verbatim, so every comment here must survive

void main() {
	vec3 static_light = vec3(0, 1, 0); // including this one
}
