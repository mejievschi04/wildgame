// Climate bands (ForestWorld.jungle_at / tundra_at / taiga_at): north (−z) snowy taiga and glacier beyond the
// northern range, then the tundra; south (+z) jungle.
float jungle_at(vec2 p) {
	return smoothstep(1300.0, 2800.0, p.y + 120.0 * sin(p.x * 0.004)) * smoothstep(-1000.0, 1100.0, p.x);
}

// The cold north beyond the northern range (ForestWorld.taiga_at): snowy taiga, frozen water, the glacier.
float taiga_at(vec2 p) {
	return (1.0 - smoothstep(-2560.0, -2020.0, p.y + 90.0 * sin(p.x * 0.0037 + 0.7))) * smoothstep(450.0, 1500.0, p.x);
}

float tundra_at(vec2 p) {
	return (1.0 - smoothstep(-1770.0, -1320.0, p.y + 85.0 * sin(p.x * 0.005 + 2.0))) * smoothstep(0.0, 900.0, p.x)
		* (1.0 - taiga_at(p));
}

// 0..1 on the glacier's ice (ForestWorld.glacier_at; gen_terrain.py glacier_at): down the river's head valley.
float glacier_at(vec2 p) {
	float rx = 3050.0 + 110.0 * sin(p.y * 0.002);
	float d = abs(p.x - rx);
	float hw = 170.0 * (0.75 + 0.7 * smoothstep(-3330.0, -4150.0, p.y)) + 28.0 * sin(p.y * 0.011 + 1.7) + 12.0 * sin(p.y * 0.047);
	return (1.0 - smoothstep(hw - 40.0, hw + 25.0, d)) * smoothstep(-3320.0, -3400.0, p.y);
}
