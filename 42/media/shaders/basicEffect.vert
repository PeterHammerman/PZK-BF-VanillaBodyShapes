#version 330

// ============================================================================
// BGB Dynamic body shape  (basicEffect + more_feminime hybrid, with progress)
//
//  LOWER BODY (belly sculpt, waist, thighs/tights, butt)  <- more_feminime tables
//  CHEST at LactationProgress = 0  -> basicEffect chest (near-vanilla)
//  CHEST at LactationProgress = 1  -> more_feminime chest
//        (anchors are the same points in both shaders, so the two delta sets
//         are simply interpolated; foreign/clothing matching parameters
//         interpolate too, so tight clothing follows the growing chest)
//  BELLY: procedural pregnancy dome driven by PregnancyProgress (0..1),
//         added on top of the static sculpt
//
// INPUTS (uniforms set per model by the BodyShapeHook Java mod; all default 0):
//     uniform float BodyShapeEnabled;    // 1 = apply ANY shaping to this model, 0 = untouched vanilla
//     uniform float LactationProgress;   // CHEST SIZE FACTOR 0..3: 0 = basicEffect chest, 1 = more_feminime,
//                                       >1 extrapolates further (sandbox 'max lactation size')
//     uniform float PregnancyProgress;   // 0..1
// The shader cannot know gender / player / NPC / zombie by itself. The hook sets
// BodyShapeEnabled = 1 ONLY for the local female player (body and her clothing)
// and 0 for every other model - that single rule excludes males, zombies and NPCs
// from ALL vertex changes, static lower body included.
// ============================================================================

// Manual switches (shader file-watcher hot-reloads on save).
const bool UPPER_VANILLA_MODE = false;          // true = skip chest/belly/waist (bulky garments)
const bool ENABLE_FOREIGN_PROXIMITY_MATCH = true;
const bool ENABLE_BGB_SCULPT = true;            // master switch for ALL displacement below
const bool ENABLE_CHEST_FOREIGN_MATCH = true;   // same per-region choices as more_feminime
const bool ENABLE_BELLY_FOREIGN_MATCH = false;
const bool ENABLE_THIGH_FOREIGN_MATCH = false;
const bool ENABLE_WAIST_FOREIGN_MATCH = false;
const bool ENABLE_LACTATION_CHEST = true;       // false = chest stays at its L=0 shape
const bool ENABLE_PREGNANCY_BELLY = true;       // false = no pregnancy dome
// Tuning aid ONLY: true applies the shape to EVERY model using this shader (males,
// zombies...) so you can preview it without the Java hook. Keep false in play.
const bool FORCE_SHAPE_FOR_ALL = false;
// Debug aid: multiplies LactationProgress before the chest blend. 1.0 = exactly
// basicEffect -> more_feminime. Values above 1 EXTRAPOLATE past more_feminime so the
// effect is easy to see while testing (try 3.0). Set back to 1.0 for real play.
const float LACTATION_GAIN = 1.0;

layout (location = 0) in vec4 vertex;
layout (location = 1) in vec4 normal;
layout (location = 2) in vec4 boneWeights;
layout (location = 3) in vec4 boneIndices;
layout (location = 4) in vec2 uv;

out vec3 vertColour;
out vec3 vertNormal;
out vec2 texCoords;

uniform mat4 ModelViewProjection;
uniform float targetDepth = 0.5;
uniform float DepthBias;
uniform mat4 MatrixPalette[60];
uniform vec2 UVScale = vec2(1,1);
uniform float HighResDepthMultiplier = 0.0; // 0.5 when drawing models to double-sized chunk textures
uniform float FinalScale = 1.0;

// --- NEW: per-model body shape inputs (see header) ---
uniform float BodyShapeEnabled = 0.0;
uniform float LactationProgress = 0.0;
uniform float PregnancyProgress = 0.0;

// SkeletonBone ordinals (fixed, engine-wide): Bip01_Pelvis=2, Bip01_Spine=3,
// Bip01_Spine1=4, Bip01_L_Thigh=20, Bip01_R_Thigh=24, DressFront=28, DressBack=30.
const int CHEST_BONE_INDEX = 4;
const int PELVIS_BONE_INDEX = 2;
const int SPINE_BONE_INDEX = 3;
const int L_THIGH_BONE_INDEX = 20;
const int R_THIGH_BONE_INDEX = 24;
const int DRESS_FRONT_BONE_INDEX = 28;
const int DRESS_BACK_BONE_INDEX = 30;
const float SCULPT_SCALE = 1.0;
const float NORMAL_ADJUST_STRENGTH = 4.0;

// Lower body: more_feminime parameters.
const float EXACT_MATCH_EPS = 0.005;
const float BELLY_THRESHOLD = 0.080;
const float BELLY_INNER = 0.5;
const float BELLY_BLEND_BAND = 0.010;
const float THIGH_THRESHOLD = 0.080;
const float THIGH_INNER = 0.5;
const float THIGH_BLEND_BAND = 0.010;
const float WAIST_THRESHOLD = 0.040;
const float WAIST_INNER = 0.5;
const float WAIST_BLEND_BAND = 0.010;

// Chest: two complete copies of the original algorithm, one per source shader.
// Their RESULTS are blended by LactationProgress, so L=0 is exactly basicEffect,
// L=1 is exactly more_feminime, and everything in between is a smooth morph.
const float CHEST_BASE_EXACT_EPS  = 0.0008;
const float CHEST_BASE_THRESHOLD  = 0.080;
const float CHEST_FEM_EXACT_EPS   = 0.005;
const float CHEST_FEM_THRESHOLD   = 0.160;
const float CHEST_INNER = 0.85;
const float CHEST_BLEND_BAND = 0.010;

// Pregnancy belly (bind-pose units: the model is ~0.97 tall, so 0.01 ~ 1.9 cm).
// Separable dome: a circular-arc profile sideways (round, not a ridge) and an asymmetric
// profile vertically (peak near navel height, fast fall-off toward the groin, gentler
// taper toward the ribs). Position-based, so clothing follows automatically.
const float PREG_MAX_PUSH       = 0.080;  // forward growth at 100% (~15 cm)
const float PREG_CENTER_Y_START = 0.535;  // apex height at the start (low, early pregnancy)...
const float PREG_CENTER_Y_END   = 0.565;  // ...rises to ~navel height (y~0.56) when full
const float PREG_RADIUS_X_START = 0.075;  // half-width
const float PREG_RADIUS_X_END   = 0.095;
const float PREG_RADIUS_Y_START = 0.045;  // height ABOVE the apex (to the ribs)
const float PREG_RADIUS_Y_END   = 0.072;
const float PREG_BOTTOM_Y       = 0.455;  // below the apex the dome ends here (lowest pelvis verts ~0.447)
const float PREG_ROUND_X        = 0.5;    // sideways profile (1-ex^2)^this: 0.5 = circular arc, lower = flatter/rounder
const float PREG_POW_LOW        = 1.3;    // fall-off below the apex (higher = less groin)
const float PREG_POW_UP         = 1.0;    // fall-off above the apex (higher = tapers sooner)
const float PREG_SPREAD         = 1.5;    // sideways push proportional to |x|
const float PREG_SAG            = 0.10;   // downward push relative to forward push
// FRONT IS -Z in this model's space (verified: toes, breast growth and the abdomen surface
// all point to -Z; the butt reaches +0.097). Abdomen front surface z ~ -0.012..-0.025,
// mid-plane ~ +0.03. Vertices with z below FULL are 'front' (dome applies fully), above NONE they
// are 'back' (never move).
const float PREG_FRONT_Z_FULL   = 0.000;
const float PREG_FRONT_Z_NONE   = 0.040;
const float PREG_ZONE_W_MIN     = 0.30;   // pelvis+spine weight ramp (soft gate)
const float PREG_ZONE_W_MAX     = 0.70;
const float PREG_NORMAL_TILT    = 1.0;    // 0 = leave shading normal alone

// ---- Chest anchors: basicEffect.vert (BASE) and more_feminime.vert (FEM), verbatim ----
const int CHEST_BASE_COUNT = 113;
const int CHEST_BASE_REAL_COUNT = 75;
const vec3 CHEST_BASE_ORIG[113] = vec3[113](
	vec3(-0.03325,0.76748,0.01081), vec3(-0.05945,0.72539,-0.00918), vec3(-0.04579,0.70090,-0.03760),
	vec3(-0.06338,0.69743,-0.02383), vec3(-0.04147,0.72828,-0.01943), vec3(-0.02218,0.69999,-0.03687),
	vec3(-0.01773,0.71968,-0.02169), vec3(-0.04026,0.64917,0.05895), vec3(-0.04590,0.68601,0.06584),
	vec3(-0.05741,0.65083,0.05160), vec3(-0.06281,0.65857,0.03673), vec3(-0.05971,0.65653,0.00084),
	vec3(-0.03984,0.65788,-0.02470), vec3(-0.04099,0.66335,-0.02525), vec3(-0.02049,0.66766,-0.02620),
	vec3(-0.06625,0.69439,0.06606), vec3(-0.08188,0.74764,0.07430), vec3(-0.08188,0.74764,0.07430),
	vec3(-0.08176,0.73860,0.06721), vec3(-0.08176,0.73860,0.06721), vec3(-0.06444,0.74532,0.00421),
	vec3(-0.06444,0.74532,0.00421), vec3(-0.06444,0.74532,0.00421), vec3(-0.06809,0.68696,-0.00005),
	vec3(-0.06867,0.69455,0.01777), vec3(-0.06996,0.68999,0.05534), vec3(-0.07829,0.73746,0.07598),
	vec3(-0.06796,0.71889,0.03816), vec3(-0.06796,0.71889,0.03816), vec3(-0.06650,0.71520,0.00029),
	vec3(-0.02232,0.67583,-0.03502), vec3(-0.04607,0.67267,-0.03551), vec3(-0.06139,0.67470,-0.01821),
	vec3(-0.03911,0.74132,-0.01151), vec3(-0.01109,0.70064,-0.03092), vec3(-0.01116,0.67675,-0.02893),
	vec3(0.00000,0.64939,0.06289), vec3(0.00000,0.64939,0.06289), vec3(0.00000,0.73527,-0.01550),
	vec3(0.03325,0.76748,0.01081), vec3(0.05945,0.72539,-0.00918), vec3(0.04579,0.70090,-0.03760),
	vec3(0.06338,0.69743,-0.02383), vec3(0.04147,0.72828,-0.01943), vec3(0.02218,0.69999,-0.03687),
	vec3(0.01773,0.71968,-0.02169), vec3(0.04026,0.64917,0.05895), vec3(0.04590,0.68601,0.06584),
	vec3(0.05741,0.65083,0.05160), vec3(0.06281,0.65857,0.03673), vec3(0.05971,0.65653,0.00084),
	vec3(0.03984,0.65788,-0.02470), vec3(0.04099,0.66335,-0.02525), vec3(0.02049,0.66766,-0.02620),
	vec3(0.06625,0.69439,0.06606), vec3(0.08188,0.74764,0.07430), vec3(0.08188,0.74764,0.07430),
	vec3(0.08176,0.73860,0.06721), vec3(0.08176,0.73860,0.06721), vec3(0.06444,0.74532,0.00421),
	vec3(0.06444,0.74532,0.00421), vec3(0.06444,0.74532,0.00421), vec3(0.06809,0.68696,-0.00005),
	vec3(0.06867,0.69455,0.01777), vec3(0.06996,0.68999,0.05534), vec3(0.07829,0.73746,0.07598),
	vec3(0.06796,0.71889,0.03816), vec3(0.06796,0.71889,0.03816), vec3(0.06650,0.71520,0.00029),
	vec3(0.02232,0.67583,-0.03502), vec3(0.04607,0.67267,-0.03551), vec3(0.06139,0.67470,-0.01821),
	vec3(0.03911,0.74132,-0.01151), vec3(0.01109,0.70064,-0.03092), vec3(0.01116,0.67675,-0.02893),
	vec3(0.06389,0.76738,0.01004), vec3(0.02505,0.80340,0.05866), vec3(0.04474,0.77711,0.07990),
	vec3(0.00000,0.67456,0.06373), vec3(0.06949,0.68874,0.03945), vec3(0.06062,0.66815,-0.00016),
	vec3(0.01570,0.66352,-0.02426), vec3(0.03016,0.80276,0.04440), vec3(0.06389,0.76738,0.01004),
	vec3(0.04913,0.73471,0.08183), vec3(0.00000,0.77433,0.07995), vec3(0.00000,0.72038,0.07808),
	vec3(0.07540,0.73080,0.02816), vec3(0.00000,0.80497,0.06292), vec3(0.03016,0.80276,0.04440),
	vec3(0.01998,0.79266,0.03278), vec3(0.00000,0.78135,0.01290), vec3(0.07540,0.73080,0.02816),
	vec3(0.00000,0.76504,0.00130), vec3(0.00000,0.67766,-0.02715), vec3(0.00000,0.70130,-0.02927),
	vec3(-0.06389,0.76738,0.01004), vec3(-0.02505,0.80340,0.05866), vec3(-0.04474,0.77711,0.07990),
	vec3(0.00000,0.67456,0.06373), vec3(-0.06949,0.68874,0.03945), vec3(-0.06062,0.66815,-0.00016),
	vec3(-0.01570,0.66352,-0.02426), vec3(-0.03016,0.80276,0.04440), vec3(-0.06389,0.76738,0.01004),
	vec3(-0.04913,0.73471,0.08183), vec3(0.00000,0.77433,0.07995), vec3(0.00000,0.72038,0.07808),
	vec3(-0.07540,0.73080,0.02816), vec3(0.00000,0.80497,0.06292), vec3(-0.03016,0.80276,0.04440),
	vec3(-0.01998,0.79266,0.03278), vec3(-0.07540,0.73080,0.02816)
);
const vec3 CHEST_BASE_DELTAS[113] = vec3[113](
	vec3(0.00244,0.00000,-0.00025), vec3(-0.00510,-0.00457,-0.00996), vec3(-0.01638,-0.00105,-0.00009),
	vec3(-0.00754,-0.00295,0.00598), vec3(0.00205,-0.00428,-0.01678), vec3(-0.01596,0.00145,-0.01149),
	vec3(-0.00307,0.00210,-0.01306), vec3(0.00414,-0.00020,-0.00548), vec3(0.00475,0.00019,0.00089),
	vec3(0.00539,0.00258,-0.00411), vec3(0.00476,-0.00331,-0.00329), vec3(-0.00025,0.00551,0.00106),
	vec3(0.00322,0.00030,0.00716), vec3(0.00090,-0.00239,0.00000), vec3(-0.00365,-0.00233,-0.00540),
	vec3(0.00766,0.00410,-0.00095), vec3(0.00444,0.00184,-0.00142), vec3(0.00444,0.00184,-0.00142),
	vec3(0.00471,-0.01035,-0.00564), vec3(0.00471,-0.01035,-0.00564), vec3(0.00307,-0.00413,-0.00329),
	vec3(0.00307,-0.00413,-0.00329), vec3(0.00307,-0.00413,-0.00329), vec3(-0.00248,0.00533,0.00568),
	vec3(0.00428,-0.00348,0.00077), vec3(0.00389,0.00150,0.00015), vec3(0.01122,-0.00742,-0.00040),
	vec3(-0.00539,-0.00691,0.00146), vec3(-0.00539,-0.00691,0.00146), vec3(-0.00256,0.00607,0.01586),
	vec3(-0.01083,-0.00199,-0.00875), vec3(-0.01314,0.00260,0.00391), vec3(-0.00224,-0.00461,0.00402),
	vec3(0.00095,0.00470,0.00078), vec3(-0.00282,0.00334,-0.01029), vec3(-0.00359,0.00368,-0.01109),
	vec3(0.00000,-0.00030,-0.00627), vec3(0.00000,-0.00030,-0.00627), vec3(-0.00006,0.00303,-0.00208),
	vec3(-0.00244,0.00000,-0.00025), vec3(0.00510,-0.00457,-0.00996), vec3(0.01638,-0.00105,-0.00009),
	vec3(0.00754,-0.00295,0.00598), vec3(-0.00205,-0.00428,-0.01678), vec3(0.01596,0.00145,-0.01149),
	vec3(0.00307,0.00210,-0.01306), vec3(-0.00414,-0.00020,-0.00548), vec3(-0.00475,0.00019,0.00089),
	vec3(-0.00539,0.00258,-0.00411), vec3(-0.00476,-0.00331,-0.00329), vec3(0.00025,0.00551,0.00106),
	vec3(-0.00322,0.00030,0.00716), vec3(-0.00090,-0.00239,0.00000), vec3(0.00365,-0.00233,-0.00540),
	vec3(-0.00766,0.00410,-0.00095), vec3(-0.00444,0.00184,-0.00142), vec3(-0.00444,0.00184,-0.00142),
	vec3(-0.00471,-0.01035,-0.00564), vec3(-0.00471,-0.01035,-0.00564), vec3(-0.00307,-0.00413,-0.00329),
	vec3(-0.00307,-0.00413,-0.00329), vec3(-0.00307,-0.00413,-0.00329), vec3(0.00248,0.00533,0.00568),
	vec3(-0.00428,-0.00348,0.00077), vec3(-0.00389,0.00150,0.00015), vec3(-0.01122,-0.00742,-0.00040),
	vec3(0.00539,-0.00691,0.00146), vec3(0.00539,-0.00691,0.00146), vec3(0.00256,0.00607,0.01586),
	vec3(0.01083,-0.00199,-0.00875), vec3(0.01314,0.00260,0.00391), vec3(0.00224,-0.00461,0.00402),
	vec3(-0.00095,0.00470,0.00078), vec3(0.00282,0.00334,-0.01029), vec3(0.00359,0.00368,-0.01109),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00080,-0.00642,0.00325), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00080,-0.00642,0.00325),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(-0.00080,-0.00642,0.00325), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(-0.00080,-0.00642,0.00325)
);
const int CHEST_FEM_COUNT = 113;
const int CHEST_FEM_REAL_COUNT = 87;
const vec3 CHEST_FEM_ORIG[113] = vec3[113](
	vec3(-0.03325,0.76748,0.01081), vec3(-0.05945,0.72539,-0.00918), vec3(-0.04579,0.70090,-0.03760),
	vec3(-0.06338,0.69743,-0.02383), vec3(-0.04147,0.72828,-0.01943), vec3(-0.02218,0.69999,-0.03687),
	vec3(-0.01773,0.71968,-0.02169), vec3(-0.04026,0.64917,0.05895), vec3(-0.04590,0.68601,0.06584),
	vec3(-0.05741,0.65083,0.05160), vec3(-0.06281,0.65857,0.03673), vec3(-0.05971,0.65653,0.00084),
	vec3(-0.06062,0.66815,-0.00016), vec3(-0.03984,0.65788,-0.02470), vec3(-0.04099,0.66335,-0.02525),
	vec3(-0.02049,0.66766,-0.02620), vec3(-0.01570,0.66352,-0.02426), vec3(-0.06625,0.69439,0.06606),
	vec3(-0.08188,0.74764,0.07430), vec3(-0.08188,0.74764,0.07430), vec3(-0.07540,0.73080,0.02816),
	vec3(-0.07540,0.73080,0.02816), vec3(-0.08176,0.73860,0.06721), vec3(-0.08176,0.73860,0.06721),
	vec3(-0.06444,0.74532,0.00421), vec3(-0.06444,0.74532,0.00421), vec3(-0.06444,0.74532,0.00421),
	vec3(-0.06809,0.68696,-0.00005), vec3(-0.06996,0.68999,0.05534), vec3(-0.07829,0.73746,0.07598),
	vec3(-0.06796,0.71889,0.03816), vec3(-0.06796,0.71889,0.03816), vec3(-0.06867,0.69455,0.01777),
	vec3(-0.06650,0.71520,0.00029), vec3(-0.02232,0.67583,-0.03502), vec3(-0.04607,0.67267,-0.03551),
	vec3(-0.06139,0.67470,-0.01821), vec3(-0.03911,0.74132,-0.01151), vec3(-0.01109,0.70064,-0.03092),
	vec3(-0.01116,0.67675,-0.02893), vec3(0.00000,0.64939,0.06289), vec3(0.00000,0.64939,0.06289),
	vec3(0.00000,0.73527,-0.01550), vec3(0.00000,0.67766,-0.02715), vec3(0.03325,0.76748,0.01081),
	vec3(0.05945,0.72539,-0.00918), vec3(0.04579,0.70090,-0.03760), vec3(0.06338,0.69743,-0.02383),
	vec3(0.04147,0.72828,-0.01943), vec3(0.02218,0.69999,-0.03687), vec3(0.01773,0.71968,-0.02169),
	vec3(0.04026,0.64917,0.05895), vec3(0.04590,0.68601,0.06584), vec3(0.05741,0.65083,0.05160),
	vec3(0.06281,0.65857,0.03673), vec3(0.05971,0.65653,0.00084), vec3(0.06062,0.66815,-0.00016),
	vec3(0.03984,0.65788,-0.02470), vec3(0.04099,0.66335,-0.02525), vec3(0.02049,0.66766,-0.02620),
	vec3(0.01570,0.66352,-0.02426), vec3(0.06625,0.69439,0.06606), vec3(0.08188,0.74764,0.07430),
	vec3(0.08188,0.74764,0.07430), vec3(0.07540,0.73080,0.02816), vec3(0.07540,0.73080,0.02816),
	vec3(0.08176,0.73860,0.06721), vec3(0.08176,0.73860,0.06721), vec3(0.06444,0.74532,0.00421),
	vec3(0.06444,0.74532,0.00421), vec3(0.06444,0.74532,0.00421), vec3(0.06809,0.68696,-0.00005),
	vec3(0.06996,0.68999,0.05534), vec3(0.07829,0.73746,0.07598), vec3(0.06796,0.71889,0.03816),
	vec3(0.06796,0.71889,0.03816), vec3(0.06867,0.69455,0.01777), vec3(0.06650,0.71520,0.00029),
	vec3(0.02232,0.67583,-0.03502), vec3(0.04607,0.67267,-0.03551), vec3(0.06139,0.67470,-0.01821),
	vec3(0.03911,0.74132,-0.01151), vec3(0.01109,0.70064,-0.03092), vec3(0.01116,0.67675,-0.02893),
	vec3(0.06389,0.76738,0.01004), vec3(0.02505,0.80340,0.05866), vec3(0.04474,0.77711,0.07990),
	vec3(0.00000,0.67456,0.06373), vec3(0.06949,0.68874,0.03945), vec3(0.03016,0.80276,0.04440),
	vec3(0.06389,0.76738,0.01004), vec3(0.04913,0.73471,0.08183), vec3(0.00000,0.77433,0.07995),
	vec3(0.00000,0.72038,0.07808), vec3(0.00000,0.80497,0.06292), vec3(0.03016,0.80276,0.04440),
	vec3(0.01998,0.79266,0.03278), vec3(0.00000,0.78135,0.01290), vec3(0.00000,0.76504,0.00130),
	vec3(0.00000,0.70130,-0.02927), vec3(-0.06389,0.76738,0.01004), vec3(-0.02505,0.80340,0.05866),
	vec3(-0.04474,0.77711,0.07990), vec3(0.00000,0.67456,0.06373), vec3(-0.06949,0.68874,0.03945),
	vec3(-0.03016,0.80276,0.04440), vec3(-0.06389,0.76738,0.01004), vec3(-0.04913,0.73471,0.08183),
	vec3(0.00000,0.77433,0.07995), vec3(0.00000,0.72038,0.07808), vec3(0.00000,0.80497,0.06292),
	vec3(-0.03016,0.80276,0.04440), vec3(-0.01998,0.79266,0.03278)
);
const vec3 CHEST_FEM_DELTAS[113] = vec3[113](
	vec3(0.00244,0.00000,-0.00025), vec3(-0.00637,-0.00016,-0.00928), vec3(-0.00747,0.01088,-0.01671),
	vec3(-0.01379,0.00454,-0.00244), vec3(-0.00529,0.00332,-0.01374), vec3(-0.00611,0.01298,-0.01724),
	vec3(0.00522,0.00726,-0.00782), vec3(0.00414,-0.00020,-0.00548), vec3(0.00475,0.00019,0.00089),
	vec3(0.00539,0.00258,-0.00411), vec3(0.00476,-0.00331,-0.00329), vec3(-0.00348,0.00912,-0.00748),
	vec3(-0.00023,-0.00480,-0.02574), vec3(0.00062,-0.00051,-0.00198), vec3(-0.00834,0.00064,-0.02390),
	vec3(-0.00371,-0.00098,-0.02354), vec3(0.00321,0.00692,0.00182), vec3(0.00766,0.00410,-0.00095),
	vec3(0.00177,0.00037,-0.00021), vec3(0.00177,0.00037,-0.00021), vec3(0.00510,-0.00900,-0.00835),
	vec3(0.00510,-0.00900,-0.00835), vec3(0.00079,-0.00051,-0.00390), vec3(0.00079,-0.00051,-0.00390),
	vec3(0.00312,-0.00139,-0.00180), vec3(0.00312,-0.00139,-0.00180), vec3(0.00312,-0.00139,-0.00180),
	vec3(-0.00673,-0.00012,-0.01103), vec3(0.00389,0.00150,0.00015), vec3(0.00861,-0.00196,-0.00201),
	vec3(-0.00825,-0.01342,-0.00832), vec3(-0.00825,-0.01342,-0.00832), vec3(0.00163,0.00187,-0.00795),
	vec3(-0.00148,0.00061,0.00109), vec3(-0.01712,0.01167,-0.03122), vec3(-0.01985,0.01875,-0.02044),
	vec3(-0.01109,0.00199,-0.01913), vec3(0.00147,0.00767,-0.00221), vec3(0.00252,0.00816,-0.01178),
	vec3(-0.00048,0.00829,-0.02088), vec3(0.00000,-0.00030,-0.00627), vec3(0.00000,-0.00030,-0.00627),
	vec3(-0.00006,0.00303,-0.00208), vec3(0.00000,0.00471,0.00000), vec3(-0.00244,0.00000,-0.00025),
	vec3(0.00637,-0.00016,-0.00928), vec3(0.00747,0.01088,-0.01671), vec3(0.01379,0.00454,-0.00244),
	vec3(0.00529,0.00332,-0.01374), vec3(0.00611,0.01298,-0.01724), vec3(-0.00522,0.00726,-0.00782),
	vec3(-0.00414,-0.00020,-0.00548), vec3(-0.00475,0.00019,0.00089), vec3(-0.00539,0.00258,-0.00411),
	vec3(-0.00476,-0.00331,-0.00329), vec3(0.00348,0.00912,-0.00748), vec3(0.00023,-0.00480,-0.02574),
	vec3(-0.00062,-0.00051,-0.00198), vec3(0.00834,0.00064,-0.02390), vec3(0.00371,-0.00098,-0.02354),
	vec3(-0.00321,0.00692,0.00182), vec3(-0.00766,0.00410,-0.00095), vec3(-0.00177,0.00037,-0.00021),
	vec3(-0.00177,0.00037,-0.00021), vec3(-0.00510,-0.00900,-0.00835), vec3(-0.00510,-0.00900,-0.00835),
	vec3(-0.00079,-0.00051,-0.00390), vec3(-0.00079,-0.00051,-0.00390), vec3(-0.00312,-0.00139,-0.00180),
	vec3(-0.00312,-0.00139,-0.00180), vec3(-0.00312,-0.00139,-0.00180), vec3(0.00673,-0.00012,-0.01103),
	vec3(-0.00389,0.00150,0.00015), vec3(-0.00861,-0.00196,-0.00201), vec3(0.00825,-0.01342,-0.00832),
	vec3(0.00825,-0.01342,-0.00832), vec3(-0.00163,0.00187,-0.00795), vec3(0.00148,0.00061,0.00109),
	vec3(0.01712,0.01167,-0.03122), vec3(0.01985,0.01875,-0.02044), vec3(0.01109,0.00199,-0.01913),
	vec3(-0.00147,0.00767,-0.00221), vec3(-0.00252,0.00816,-0.01178), vec3(0.00048,0.00829,-0.02088),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000)
);

const int BELLY_SCULPT_COUNT = 49;
const int BELLY_REAL_COUNT = 38;
const vec3 BELLY_SCULPT_ORIG[49] = vec3[49](
	vec3(-0.04191,0.56933,0.08047), vec3(-0.08165,0.54716,0.01237), vec3(-0.05131,0.56260,-0.01718),
	vec3(-0.01198,0.46129,0.00859), vec3(-0.01198,0.46129,0.00859), vec3(-0.02900,0.45401,0.07883),
	vec3(-0.02900,0.45401,0.07883), vec3(-0.09174,0.51040,0.02234), vec3(-0.07756,0.52349,0.07179),
	vec3(-0.04295,0.52946,0.09671), vec3(-0.08587,0.46885,0.07046), vec3(-0.04372,0.47908,0.09135),
	vec3(0.00000,0.55061,0.07686), vec3(0.00000,0.55061,0.07686), vec3(0.00000,0.56043,-0.02352),
	vec3(0.00000,0.51914,0.09445), vec3(0.00000,0.51914,0.09445), vec3(0.00000,0.48428,0.09101),
	vec3(0.00000,0.48428,0.09101), vec3(0.00000,0.48428,0.09101), vec3(0.00000,0.47457,0.08587),
	vec3(0.00000,0.47457,0.08587), vec3(0.00000,0.44664,0.08475), vec3(0.04191,0.56933,0.08047),
	vec3(0.08165,0.54716,0.01237), vec3(0.05131,0.56260,-0.01718), vec3(0.01198,0.46129,0.00859),
	vec3(0.01198,0.46129,0.00859), vec3(0.02900,0.45401,0.07883), vec3(0.02900,0.45401,0.07883),
	vec3(0.09174,0.51040,0.02234), vec3(0.07756,0.52349,0.07179), vec3(0.04295,0.52946,0.09671),
	vec3(0.08587,0.46885,0.07046), vec3(0.04372,0.47908,0.09135), vec3(0.07276,0.56169,0.05368),
	vec3(0.07184,0.51551,-0.00469), vec3(0.04115,0.50675,-0.01379), vec3(0.00000,0.46571,-0.01217),
	vec3(0.00000,0.45380,0.02573), vec3(0.00000,0.49912,-0.01884), vec3(0.00000,0.45380,0.02573),
	vec3(-0.07276,0.56169,0.05368), vec3(-0.07184,0.51551,-0.00469), vec3(-0.04115,0.50675,-0.01379),
	vec3(0.00000,0.45380,0.02573), vec3(0.04115,0.50675,-0.01379), vec3(0.00000,0.49912,-0.01884),
	vec3(-0.04115,0.50675,-0.01379)
);
const vec3 BELLY_SCULPT_DELTAS[49] = vec3[49](
	vec3(-0.00118,-0.01218,0.00663), vec3(-0.00983,-0.00006,-0.00036), vec3(0.00000,-0.00172,-0.00516),
	vec3(-0.00108,0.01212,0.00421), vec3(-0.00108,0.01212,0.00421), vec3(-0.01353,-0.02498,0.00727),
	vec3(-0.01353,-0.02498,0.00727), vec3(-0.00689,0.00889,0.00106), vec3(-0.00266,0.00112,-0.00512),
	vec3(-0.00488,-0.00398,-0.00651), vec3(0.00574,0.01136,0.00279), vec3(-0.00081,0.00500,-0.00075),
	vec3(0.00000,-0.00979,0.01807), vec3(0.00000,-0.00979,0.01807), vec3(0.00000,-0.00172,-0.00516),
	vec3(0.00000,0.00634,0.00323), vec3(0.00000,0.00634,0.00323), vec3(0.00000,-0.01948,0.00234),
	vec3(0.00000,-0.01948,0.00234), vec3(0.00000,-0.01948,0.00234), vec3(0.00000,-0.00451,-0.01085),
	vec3(0.00000,-0.00451,-0.01085), vec3(0.00000,-0.01914,0.00622), vec3(0.00118,-0.01218,0.00663),
	vec3(0.00983,-0.00006,-0.00036), vec3(0.00000,-0.00172,-0.00516), vec3(0.00108,0.01212,0.00421),
	vec3(0.00108,0.01212,0.00421), vec3(0.01353,-0.02498,0.00727), vec3(0.01353,-0.02498,0.00727),
	vec3(0.00689,0.00889,0.00106), vec3(0.00266,0.00112,-0.00512), vec3(0.00488,-0.00398,-0.00651),
	vec3(-0.00574,0.01136,0.00279), vec3(0.00081,0.00500,-0.00075), vec3(-0.00030,0.00060,0.00000),
	vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00344,0.01058),
	vec3(0.00000,0.00220,0.00278), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00220,0.00278),
	vec3(0.00030,0.00060,0.00000), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00220,0.00278), vec3(0.00000,0.00000,0.00000), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,0.00000,0.00000)
);

const int THIGH_SCULPT_COUNT = 44;
const int THIGH_REAL_COUNT = 28;
const vec3 THIGH_SCULPT_ORIG[44] = vec3[44](
	vec3(-0.10680,0.36736,0.02020), vec3(-0.09954,0.46550,0.02254), vec3(-0.07444,0.36447,-0.00732),
	vec3(-0.07444,0.36447,-0.00732), vec3(-0.04578,0.36660,0.07912), vec3(-0.02889,0.36173,0.01711),
	vec3(-0.02889,0.36173,0.01711), vec3(-0.09082,0.43923,0.07519), vec3(-0.09082,0.43923,0.07519),
	vec3(-0.09331,0.37232,0.07147), vec3(-0.09331,0.37232,0.07147), vec3(-0.02131,0.37215,-0.01824),
	vec3(-0.04184,0.37305,0.08668), vec3(0.00000,0.37537,0.08761), vec3(0.00000,0.37289,-0.02130),
	vec3(0.10680,0.36736,0.02020), vec3(0.09954,0.46550,0.02254), vec3(0.07444,0.36447,-0.00732),
	vec3(0.07444,0.36447,-0.00732), vec3(0.04578,0.36660,0.07912), vec3(0.02889,0.36173,0.01711),
	vec3(0.02889,0.36173,0.01711), vec3(0.09082,0.43923,0.07519), vec3(0.09082,0.43923,0.07519),
	vec3(0.09331,0.37232,0.07147), vec3(0.09331,0.37232,0.07147), vec3(0.01962,0.37222,-0.01855),
	vec3(0.04242,0.37373,0.08405), vec3(0.06131,0.46288,-0.01349), vec3(-0.06131,0.46288,-0.01349),
	vec3(0.06131,0.46288,-0.01349), vec3(0.01130,0.46186,-0.02042), vec3(-0.01172,0.46202,-0.02022),
	vec3(0.00000,0.45996,-0.02287), vec3(-0.06131,0.46288,-0.01349), vec3(0.00000,0.49912,-0.01884),
	vec3(0.00000,0.44664,0.08475), vec3(0.00000,0.47457,0.08587), vec3(0.00000,0.57565,0.06380),
	vec3(0.00000,0.55061,0.07686), vec3(0.09174,0.51040,0.02234), vec3(0.08165,0.54716,0.01237),
	vec3(-0.09174,0.51040,0.02234), vec3(-0.08165,0.54716,0.01237)
);
const vec3 THIGH_SCULPT_DELTAS[44] = vec3[44](
	vec3(0.00256,-0.00029,0.00478), vec3(-0.00434,-0.00534,0.00480), vec3(0.00000,0.00043,-0.00387),
	vec3(0.00000,0.00043,-0.00387), vec3(0.00857,0.00088,0.00544), vec3(0.00010,0.00327,0.00108),
	vec3(0.00010,0.00327,0.00108), vec3(0.01047,-0.00844,-0.00100), vec3(0.01047,-0.00844,-0.00100),
	vec3(0.01101,0.00078,-0.00112), vec3(0.01101,0.00078,-0.00112), vec3(0.00000,0.00043,-0.00387),
	vec3(0.00000,0.00000,0.00387), vec3(0.00000,0.00000,0.00387), vec3(0.00000,0.00043,-0.00387),
	vec3(-0.00256,-0.00029,0.00478), vec3(0.00434,-0.00534,0.00480), vec3(0.00000,0.00043,-0.00387),
	vec3(0.00000,0.00043,-0.00387), vec3(-0.00857,0.00088,0.00544), vec3(-0.00010,0.00327,0.00108),
	vec3(-0.00010,0.00327,0.00108), vec3(-0.01047,-0.00844,-0.00100), vec3(-0.01047,-0.00844,-0.00100),
	vec3(-0.01101,0.00078,-0.00112), vec3(-0.01101,0.00078,-0.00112), vec3(0.00000,0.00043,-0.00387),
	vec3(0.00000,0.00000,0.00387), vec3(0.00587,-0.00592,-0.00053), vec3(-0.00587,-0.00592,-0.00053),
	vec3(0.00587,-0.00592,-0.00053), vec3(0.00035,-0.00564,-0.00003), vec3(0.00035,-0.00564,-0.00003),
	vec3(0.00000,-0.00449,0.00010), vec3(-0.00587,-0.00592,-0.00053), vec3(0.00000,0.00000,0.00000),
	vec3(0.00000,-0.01914,0.00622), vec3(0.00000,-0.00451,-0.01085), vec3(0.00000,-0.00265,0.02008),
	vec3(0.00000,-0.00979,0.01807), vec3(0.00689,0.00889,0.00106), vec3(0.00983,-0.00006,-0.00036),
	vec3(-0.00689,0.00889,0.00106), vec3(-0.00983,-0.00006,-0.00036)
);

const int WAIST_SCULPT_COUNT = 19;
const int WAIST_REAL_COUNT = 19;
const vec3 WAIST_SCULPT_ORIG[19] = vec3[19](
	vec3(-0.03725,0.59052,0.06636), vec3(-0.06489,0.58854,0.04313), vec3(-0.07291,0.57694,0.00699),
	vec3(-0.03426,0.60606,0.05851), vec3(-0.03788,0.61906,-0.02015), vec3(-0.05879,0.61858,0.00619),
	vec3(-0.05663,0.61067,0.03785), vec3(0.00000,0.57565,0.06380), vec3(0.00000,0.57565,0.06380),
	vec3(0.00000,0.61814,-0.02505), vec3(0.00000,0.60426,0.06005), vec3(0.00000,0.60426,0.06005),
	vec3(0.03725,0.59052,0.06636), vec3(0.06489,0.58854,0.04313), vec3(0.07291,0.57694,0.00699),
	vec3(0.03426,0.60606,0.05851), vec3(0.03788,0.61906,-0.02015), vec3(0.05879,0.61858,0.00619),
	vec3(0.05663,0.61067,0.03785)
);
const vec3 WAIST_SCULPT_DELTAS[19] = vec3[19](
	vec3(0.00234,-0.00361,0.00642), vec3(0.00244,0.00000,-0.00003), vec3(-0.00460,0.00066,-0.00038),
	vec3(-0.00010,0.01015,-0.00250), vec3(0.00140,0.00418,-0.00250), vec3(0.00528,0.00657,-0.00131),
	vec3(0.00498,0.00746,0.00228), vec3(0.00000,-0.00265,0.02008), vec3(0.00000,-0.00265,0.02008),
	vec3(0.00000,0.00418,-0.00250), vec3(0.00000,0.00314,0.00343), vec3(0.00000,0.00314,0.00343),
	vec3(-0.00234,-0.00361,0.00642), vec3(-0.00244,0.00000,-0.00003), vec3(0.00460,0.00066,-0.00038),
	vec3(0.00010,0.01015,-0.00250), vec3(-0.00140,0.00418,-0.00250), vec3(-0.00528,0.00657,-0.00131),
	vec3(-0.00498,0.00746,0.00228)
);

void main()
{
	vec4 position = vec4(vertex.xyz, 1.0);
	vec4 normal = vec4(normal.xyz, 0.0);
	// Sum of every sculpt displacement applied - used to tilt the normal afterwards.
	vec3 totalDisplacement = vec3(0.0);
	vec3 bellyNormalTilt = vec3(0.0);

	// Master gate: everything below that moves a vertex checks sculptOn.
	bool sculptOn = ENABLE_BGB_SCULPT && (BodyShapeEnabled > 0.5 || FORCE_SHAPE_FOR_ALL);

	float lact = ENABLE_LACTATION_CHEST ? clamp(LactationProgress, 0.0, 3.0) : 0.0;
	float lactEff = lact * LACTATION_GAIN;   // unclamped on purpose (see LACTATION_GAIN)
	float preg = ENABLE_PREGNANCY_BELLY ? clamp(PregnancyProgress, 0.0, 1.0) : 0.0;

	texCoords = uv * UVScale.xy;

	mat4 boneEffect = mat4(0.0);
	float chestWeight = 0.0;
	float bellyWeight = 0.0;
	float thighWeight = 0.0;
	float waistWeight = 0.0;
	if(boneWeights.x > 0.0) {
		boneEffect += MatrixPalette[int(boneIndices.x)] * boneWeights.x;
		if (int(boneIndices.x) == CHEST_BONE_INDEX) chestWeight += boneWeights.x;
		if (int(boneIndices.x) == PELVIS_BONE_INDEX) bellyWeight += boneWeights.x;
		if (int(boneIndices.x) == L_THIGH_BONE_INDEX || int(boneIndices.x) == R_THIGH_BONE_INDEX
		 || int(boneIndices.x) == DRESS_FRONT_BONE_INDEX || int(boneIndices.x) == DRESS_BACK_BONE_INDEX) thighWeight += boneWeights.x;
		if (int(boneIndices.x) == SPINE_BONE_INDEX) waistWeight += boneWeights.x;
	}
	if(boneWeights.y > 0.0) {
		boneEffect += MatrixPalette[int(boneIndices.y)] * boneWeights.y;
		if (int(boneIndices.y) == CHEST_BONE_INDEX) chestWeight += boneWeights.y;
		if (int(boneIndices.y) == PELVIS_BONE_INDEX) bellyWeight += boneWeights.y;
		if (int(boneIndices.y) == L_THIGH_BONE_INDEX || int(boneIndices.y) == R_THIGH_BONE_INDEX
		 || int(boneIndices.y) == DRESS_FRONT_BONE_INDEX || int(boneIndices.y) == DRESS_BACK_BONE_INDEX) thighWeight += boneWeights.y;
		if (int(boneIndices.y) == SPINE_BONE_INDEX) waistWeight += boneWeights.y;
	}
	if(boneWeights.z > 0.0) {
		boneEffect += MatrixPalette[int(boneIndices.z)] * boneWeights.z;
		if (int(boneIndices.z) == CHEST_BONE_INDEX) chestWeight += boneWeights.z;
		if (int(boneIndices.z) == PELVIS_BONE_INDEX) bellyWeight += boneWeights.z;
		if (int(boneIndices.z) == L_THIGH_BONE_INDEX || int(boneIndices.z) == R_THIGH_BONE_INDEX
		 || int(boneIndices.z) == DRESS_FRONT_BONE_INDEX || int(boneIndices.z) == DRESS_BACK_BONE_INDEX) thighWeight += boneWeights.z;
		if (int(boneIndices.z) == SPINE_BONE_INDEX) waistWeight += boneWeights.z;
	}
	if(boneWeights.w > 0.0) {
		boneEffect += MatrixPalette[int(boneIndices.w)] * boneWeights.w;
		if (int(boneIndices.w) == CHEST_BONE_INDEX) chestWeight += boneWeights.w;
		if (int(boneIndices.w) == PELVIS_BONE_INDEX) bellyWeight += boneWeights.w;
		if (int(boneIndices.w) == L_THIGH_BONE_INDEX || int(boneIndices.w) == R_THIGH_BONE_INDEX
		 || int(boneIndices.w) == DRESS_FRONT_BONE_INDEX || int(boneIndices.w) == DRESS_BACK_BONE_INDEX) thighWeight += boneWeights.w;
		if (int(boneIndices.w) == SPINE_BONE_INDEX) waistWeight += boneWeights.w;
	}

	// ---- CHEST: basicEffect (lact = 0) -> more_feminime (lact = 1) ----
	// Each source algorithm runs unchanged; only the passes with non-zero weight run.
	if (chestWeight > 0.5 && !UPPER_VANILLA_MODE && sculptOn) {
		vec3 chestBlend = vec3(0.0);
		if (lactEff != 1.0)
		{
			vec3 chestBase = vec3(0.0);
			int exactIdx = -1;
			for (int si = 0; si < CHEST_BASE_COUNT; si++) {
				if (distance(vertex.xyz, CHEST_BASE_ORIG[si]) < CHEST_BASE_EXACT_EPS) { exactIdx = si; break; }
			}
			if (exactIdx >= 0) {
				chestBase = CHEST_BASE_DELTAS[exactIdx];
			} else if (ENABLE_FOREIGN_PROXIMITY_MATCH && ENABLE_CHEST_FOREIGN_MATCH) {
				float d1 = CHEST_BASE_THRESHOLD;
				float d2 = CHEST_BASE_THRESHOLD;
				vec3 delta1 = vec3(0.0);
				vec3 delta2 = vec3(0.0);
				for (int si = 0; si < CHEST_BASE_REAL_COUNT; si++) {
					float d = distance(vertex.xyz, CHEST_BASE_ORIG[si]);
					if (d < d1) {
						d2 = d1; delta2 = delta1;
						d1 = d; delta1 = CHEST_BASE_DELTAS[si];
					} else if (d < d2) {
						d2 = d; delta2 = CHEST_BASE_DELTAS[si];
					}
				}
				if (d1 < CHEST_BASE_THRESHOLD) {
					float envelope = 1.0 - smoothstep(CHEST_BASE_THRESHOLD * CHEST_INNER, CHEST_BASE_THRESHOLD, d1);
					float tie = 1.0 - clamp((d2 - d1) / CHEST_BLEND_BAND, 0.0, 1.0);
					vec3 dirBlend = mix(delta1, delta2, 0.5 * tie);
					float dirLen = length(dirBlend);
					if (dirLen > 0.00001) {
						float magMax = max(length(delta1), length(delta2));
						chestBase = (dirBlend / dirLen) * magMax * envelope;
					}
				}
			}
			chestBlend += chestBase * (1.0 - lactEff);
		}
		if (lactEff != 0.0)
		{
			vec3 chestFem = vec3(0.0);
			int exactIdx = -1;
			for (int si = 0; si < CHEST_FEM_COUNT; si++) {
				if (distance(vertex.xyz, CHEST_FEM_ORIG[si]) < CHEST_FEM_EXACT_EPS) { exactIdx = si; break; }
			}
			if (exactIdx >= 0) {
				chestFem = CHEST_FEM_DELTAS[exactIdx];
			} else if (ENABLE_FOREIGN_PROXIMITY_MATCH && ENABLE_CHEST_FOREIGN_MATCH) {
				float d1 = CHEST_FEM_THRESHOLD;
				float d2 = CHEST_FEM_THRESHOLD;
				vec3 delta1 = vec3(0.0);
				vec3 delta2 = vec3(0.0);
				for (int si = 0; si < CHEST_FEM_REAL_COUNT; si++) {
					float d = distance(vertex.xyz, CHEST_FEM_ORIG[si]);
					if (d < d1) {
						d2 = d1; delta2 = delta1;
						d1 = d; delta1 = CHEST_FEM_DELTAS[si];
					} else if (d < d2) {
						d2 = d; delta2 = CHEST_FEM_DELTAS[si];
					}
				}
				if (d1 < CHEST_FEM_THRESHOLD) {
					float envelope = 1.0 - smoothstep(CHEST_FEM_THRESHOLD * CHEST_INNER, CHEST_FEM_THRESHOLD, d1);
					float tie = 1.0 - clamp((d2 - d1) / CHEST_BLEND_BAND, 0.0, 1.0);
					vec3 dirBlend = mix(delta1, delta2, 0.5 * tie);
					float dirLen = length(dirBlend);
					if (dirLen > 0.00001) {
						float magMax = max(length(delta1), length(delta2));
						chestFem = (dirBlend / dirLen) * magMax * envelope;
					}
				}
			}
			chestBlend += chestFem * lactEff;
		}
		vec3 chestApplied = chestBlend * SCULPT_SCALE;
		position.xyz += chestApplied;
		totalDisplacement += chestApplied;
	}
	if (bellyWeight > 0.5 && !UPPER_VANILLA_MODE && sculptOn) {
		int bellyExactIdx = -1;
		for (int si = 0; si < BELLY_SCULPT_COUNT; si++) {
			if (distance(vertex.xyz, BELLY_SCULPT_ORIG[si]) < EXACT_MATCH_EPS) { bellyExactIdx = si; break; }
		}
		if (bellyExactIdx >= 0) {
			vec3 bellyApplied = BELLY_SCULPT_DELTAS[bellyExactIdx] * SCULPT_SCALE;
			position.xyz += bellyApplied;
			totalDisplacement += bellyApplied;
		} else if (ENABLE_FOREIGN_PROXIMITY_MATCH && ENABLE_BELLY_FOREIGN_MATCH) {
			float bellyD1 = BELLY_THRESHOLD;
			float bellyD2 = BELLY_THRESHOLD;
			vec3 bellyDelta1 = vec3(0.0);
			vec3 bellyDelta2 = vec3(0.0);
			for (int si = 0; si < BELLY_REAL_COUNT; si++) {
				float d = distance(vertex.xyz, BELLY_SCULPT_ORIG[si]);
				if (d < bellyD1) {
					bellyD2 = bellyD1; bellyDelta2 = bellyDelta1;
					bellyD1 = d; bellyDelta1 = BELLY_SCULPT_DELTAS[si];
				} else if (d < bellyD2) {
					bellyD2 = d; bellyDelta2 = BELLY_SCULPT_DELTAS[si];
				}
			}
			if (bellyD1 < BELLY_THRESHOLD) {
				float envelope = 1.0 - smoothstep(BELLY_THRESHOLD * BELLY_INNER, BELLY_THRESHOLD, bellyD1);
				float tie = 1.0 - clamp((bellyD2 - bellyD1) / BELLY_BLEND_BAND, 0.0, 1.0);
				// Direction blends smoothly between the top-2 (no sawtooth seams), but
				// MAGNITUDE is the larger of the two candidates so clothing offset from
				// the body is pushed far enough not to clip.
				vec3 bellyDirBlend = mix(bellyDelta1, bellyDelta2, 0.5 * tie);
				float bellyDirLen = length(bellyDirBlend);
				if (bellyDirLen > 0.00001) {
					float bellyMagMax = max(length(bellyDelta1), length(bellyDelta2));
					vec3 bellyApplied = (bellyDirBlend / bellyDirLen) * bellyMagMax * envelope * SCULPT_SCALE;
					position.xyz += bellyApplied;
					totalDisplacement += bellyApplied;
				}
			}
		}
	}
	if (thighWeight > 0.5 && sculptOn) {
		int thighExactIdx = -1;
		for (int si = 0; si < THIGH_SCULPT_COUNT; si++) {
			if (distance(vertex.xyz, THIGH_SCULPT_ORIG[si]) < EXACT_MATCH_EPS) { thighExactIdx = si; break; }
		}
		if (thighExactIdx >= 0) {
			vec3 thighApplied = THIGH_SCULPT_DELTAS[thighExactIdx] * SCULPT_SCALE;
			position.xyz += thighApplied;
			totalDisplacement += thighApplied;
		} else if (ENABLE_FOREIGN_PROXIMITY_MATCH && ENABLE_THIGH_FOREIGN_MATCH) {
			float thighD1 = THIGH_THRESHOLD;
			float thighD2 = THIGH_THRESHOLD;
			vec3 thighDelta1 = vec3(0.0);
			vec3 thighDelta2 = vec3(0.0);
			for (int si = 0; si < THIGH_REAL_COUNT; si++) {
				float d = distance(vertex.xyz, THIGH_SCULPT_ORIG[si]);
				if (d < thighD1) {
					thighD2 = thighD1; thighDelta2 = thighDelta1;
					thighD1 = d; thighDelta1 = THIGH_SCULPT_DELTAS[si];
				} else if (d < thighD2) {
					thighD2 = d; thighDelta2 = THIGH_SCULPT_DELTAS[si];
				}
			}
			if (thighD1 < THIGH_THRESHOLD) {
				float envelope = 1.0 - smoothstep(THIGH_THRESHOLD * THIGH_INNER, THIGH_THRESHOLD, thighD1);
				float tie = 1.0 - clamp((thighD2 - thighD1) / THIGH_BLEND_BAND, 0.0, 1.0);
				// Direction blends smoothly between the top-2 (no sawtooth seams), but
				// MAGNITUDE is the larger of the two candidates so clothing offset from
				// the body is pushed far enough not to clip.
				vec3 thighDirBlend = mix(thighDelta1, thighDelta2, 0.5 * tie);
				float thighDirLen = length(thighDirBlend);
				if (thighDirLen > 0.00001) {
					float thighMagMax = max(length(thighDelta1), length(thighDelta2));
					vec3 thighApplied = (thighDirBlend / thighDirLen) * thighMagMax * envelope * SCULPT_SCALE;
					position.xyz += thighApplied;
					totalDisplacement += thighApplied;
				}
			}
		}
	}
	if (waistWeight > 0.5 && !UPPER_VANILLA_MODE && sculptOn) {
		int waistExactIdx = -1;
		for (int si = 0; si < WAIST_SCULPT_COUNT; si++) {
			if (distance(vertex.xyz, WAIST_SCULPT_ORIG[si]) < EXACT_MATCH_EPS) { waistExactIdx = si; break; }
		}
		if (waistExactIdx >= 0) {
			vec3 waistApplied = WAIST_SCULPT_DELTAS[waistExactIdx] * SCULPT_SCALE;
			position.xyz += waistApplied;
			totalDisplacement += waistApplied;
		} else if (ENABLE_FOREIGN_PROXIMITY_MATCH && ENABLE_WAIST_FOREIGN_MATCH) {
			float waistD1 = WAIST_THRESHOLD;
			float waistD2 = WAIST_THRESHOLD;
			vec3 waistDelta1 = vec3(0.0);
			vec3 waistDelta2 = vec3(0.0);
			for (int si = 0; si < WAIST_REAL_COUNT; si++) {
				float d = distance(vertex.xyz, WAIST_SCULPT_ORIG[si]);
				if (d < waistD1) {
					waistD2 = waistD1; waistDelta2 = waistDelta1;
					waistD1 = d; waistDelta1 = WAIST_SCULPT_DELTAS[si];
				} else if (d < waistD2) {
					waistD2 = d; waistDelta2 = WAIST_SCULPT_DELTAS[si];
				}
			}
			if (waistD1 < WAIST_THRESHOLD) {
				float envelope = 1.0 - smoothstep(WAIST_THRESHOLD * WAIST_INNER, WAIST_THRESHOLD, waistD1);
				float tie = 1.0 - clamp((waistD2 - waistD1) / WAIST_BLEND_BAND, 0.0, 1.0);
				// Direction blends smoothly between the top-2 (no sawtooth seams), but
				// MAGNITUDE is the larger of the two candidates so clothing offset from
				// the body is pushed far enough not to clip.
				vec3 waistDirBlend = mix(waistDelta1, waistDelta2, 0.5 * tie);
				float waistDirLen = length(waistDirBlend);
				if (waistDirLen > 0.00001) {
					float waistMagMax = max(length(waistDelta1), length(waistDelta2));
					vec3 waistApplied = (waistDirBlend / waistDirLen) * waistMagMax * envelope * SCULPT_SCALE;
					position.xyz += waistApplied;
					totalDisplacement += waistApplied;
				}
			}
		}
	}

	// ---- PREGNANCY BELLY: procedural dome, position-based ----
	// Applies to any vertex weighted to pelvis+spine (body AND clothing) whose
	// bind-pose position lies inside the dome footprint on the FRONT (-Z) of the body.
	if (preg > 0.0 && !UPPER_VANILLA_MODE && sculptOn) {
		float zone = smoothstep(PREG_ZONE_W_MIN, PREG_ZONE_W_MAX, bellyWeight + waistWeight);
		float front = 1.0 - smoothstep(PREG_FRONT_Z_FULL, PREG_FRONT_Z_NONE, vertex.z);
		float size = preg * preg * (3.0 - 2.0 * preg);   // slow start, slow finish
		float cy = mix(PREG_CENTER_Y_START, PREG_CENTER_Y_END, size);
		float rx = mix(PREG_RADIUS_X_START, PREG_RADIUS_X_END, size);
		bool below = vertex.y < cy;
		// below the apex the dome is squeezed so it ends at PREG_BOTTOM_Y (no groin crease)
		float ry = below ? max(cy - PREG_BOTTOM_Y, 0.01) : mix(PREG_RADIUS_Y_START, PREG_RADIUS_Y_END, size);
		float pw = below ? PREG_POW_LOW : PREG_POW_UP;
		float ex = vertex.x / rx;
		float ey = (vertex.y - cy) / ry;
		float ax = 1.0 - ex * ex;
		float ay = 1.0 - ey * ey;
		if (ax > 0.0 && ay > 0.0 && zone > 0.0 && front > 0.0) {
			float fx = pow(ax, PREG_ROUND_X);               // round across the body
			float fy = pow(ay, pw);                         // peak at the apex, tapers up/down
			float push = PREG_MAX_PUSH * size * front * zone;
			position.xyz += push * fx * fy * vec3(vertex.x * PREG_SPREAD, -PREG_SAG, -1.0);   // -Z = forward
			// analytic slope of h = push*fx*fy -> lighting follows the new surface.
			// (for a bulge toward -Z the outward normal is (-h_x, -h_y, -1))
			float axs = max(ax, 0.02);                      // keep the slope finite at the very rim
			float dfx = -PREG_ROUND_X * pow(axs, PREG_ROUND_X - 1.0) * 2.0 * ex / rx;
			float dfy = -pw * pow(ay, pw - 1.0) * 2.0 * ey / ry;
			float dhdx = push * dfx * fy;
			float dhdy = push * fx * dfy;
			// capped: at the dome rim the slope is steep, but shading must never flip
			bellyNormalTilt = clamp(vec3(-dhdx, -dhdy, 0.0) * PREG_NORMAL_TILT, vec3(-2.0), vec3(2.0));
		}
	}

	// Tilt the bind-pose normal towards the displacement direction so lighting
	// roughly follows the new bulged surface instead of the flat original one.
	// bellyNormalTilt is the analytic slope of the pregnancy dome (see above).
	if (dot(totalDisplacement, totalDisplacement) > 0.0 || dot(bellyNormalTilt, bellyNormalTilt) > 0.0) {
		normal.xyz = normalize(normal.xyz + totalDisplacement * NORMAL_ADJUST_STRENGTH + bellyNormalTilt);
	}

	normal = boneEffect * normal;
	vertNormal = normal.xyz;

#if 1
	vertColour = vec3(1.0);
#else
	vec3 scalevec;
	mat4 m = boneEffect;

    scalevec.x = length(vec3(m[0][0], m[0][1], m[0][2]));
    scalevec.y = length(vec3(m[1][0], m[1][1], m[1][2]));
    scalevec.z = length(vec3(m[2][0], m[2][1], m[2][2]));
    float scale = length(scalevec);
	float blood = scale;
	blood = clamp(blood, 0.0, 0.01)  * 100.0;
	vertColour = vec3(1.0,blood,blood);


#endif

	vec4 positionScaled = boneEffect * position;

	positionScaled.xyz *= FinalScale;
	vec4 o = ModelViewProjection * positionScaled;

	vec4 origin = ModelViewProjection * vec4(0, 0, 0, 1);
	o.z += (origin.z - o.z) * HighResDepthMultiplier;

//	o.z -= DepthBias;
//	o.z /= 16.0f;
	float clip = ((o.z+1.0) / 2.0); // -1,+1 -> 0,2 -> 0,1
	clip += targetDepth - 0.5;
	o.z = (clip*2)-1; // 0-1 -> 0-2 -> -1,+1

	gl_Position = o;
}
