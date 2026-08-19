// Material evaluation result - common output format for all hit groups.
// Standard materials and custom ShaderMaterials both produce this struct.

struct MaterialResult {
	vec3 albedo;
	float alpha;
	float roughness;
	float metalness;
	float specular; // Dielectric specular reflectance control [0..1], default 0.5 -> F0 = 0.04.
	vec3 emissive;
	vec3 normal; // Final shading normal (world space, after normal mapping).

	// --- Roadmap E1: transmission. ---
	float transmission; // Mix weight against the base layer, [0..1]. 0 = opaque.
	float ior; // RAW ior property. shade_and_bounce resolves it against `specular`.
	float thickness; // 0 = thin-walled: no refraction bend, no medium, no absorption.
	vec3 attenuation; // (1 - attenuation_color) * attenuation_density, extinction per metre.
	vec3 specular_tint; // glTF specularColorFactor. Tints the DIELECTRIC F0 only.
	float specular_factor; // glTF specularFactor. Scales the dielectric F0.
};

/// Sensible default for a mid-grey diffuse surface.
MaterialResult default_material_result(vec3 geometry_normal) {
	MaterialResult r;
	r.albedo = vec3(0.8);
	r.alpha = 1.0;
	r.roughness = 0.5;
	r.metalness = 0.0;
	r.specular = 0.5;
	r.emissive = vec3(0.0);
	r.normal = geometry_normal;
	// Opaque by default. transmission == 0 is what keeps every existing material
	// and every custom ShaderMaterial on the pre-E1 code path (see the dispatch
	// in shade_and_bounce).
	r.transmission = 0.0;
	r.ior = 1.5;
	r.thickness = 0.0;
	r.attenuation = vec3(0.0);
	r.specular_tint = vec3(1.0);
	r.specular_factor = 1.0;
	return r;
}
