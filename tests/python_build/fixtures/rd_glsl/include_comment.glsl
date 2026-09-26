#[compute]

#version 450

#VERSION_DEFINES

#include "_included.glsl"
#include "_included_2.glsl" // trailing comment on the second of two adjacent includes
// a comment that merely mentions #include "nothing.glsl" must not be chased

void main() {
	float t = M_PI + M_TAU;
}
