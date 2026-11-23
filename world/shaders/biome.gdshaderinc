// Climate bands (ForestWorld.jungle_at / tundra_at): north (−z) tundra, south (+z) jungle.
float jungle_at(vec2 p) {
	return smoothstep(650.0, 1150.0, p.y + 120.0 * sin(p.x * 0.004) + 80.0 * sin(p.x * 0.011 + 1.0));
}

float tundra_at(vec2 p) {
	return 1.0 - smoothstep(-1550.0, -1200.0, p.y + 100.0 * sin(p.x * 0.005 + 2.0) + 60.0 * sin(p.x * 0.013));
}
