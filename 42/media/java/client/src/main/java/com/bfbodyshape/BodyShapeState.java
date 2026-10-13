package com.bfbodyshape;

import zombie.characters.IsoGameCharacter;
import zombie.core.opengl.ShaderProgram;
import zombie.core.skinnedmodel.model.ModelInstance;
import zombie.core.skinnedmodel.model.ModelSlotRenderData;
import zombie.core.skinnedmodel.shader.Shader;

/**
 * Bridge between the game thread (Lua) and the render thread (shader patches).
 *
 *  - Lua calls BFMDB_SetBodyShape(...) -> {@link #set}: publishes ONE immutable snapshot
 *    (target character + progress values). Written on the game thread.
 *  - The Shader patches call {@link #applyTo} / {@link #reset} on the render thread, once per
 *    model instance that is drawn with the body shader.
 *
 * The shader uniforms are only ever non-zero for model slots whose character is exactly the
 * snapshot's target. Every other model (males, zombies, NPCs, other players) is explicitly
 * written back to 0 on every draw, because GL uniforms persist on the program between draws.
 */
public final class BodyShapeState {
    /** Name of the body shader (media/shaders/basicEffect.vert/.frag). */
    public static final String SHADER_NAME = "basicEffect";

    /** UI avatars whose model instance has no character are treated as the player's own. */
    public static final boolean AVATAR_NULL_CHARACTER_MATCHES = true;

    /** Seconds for progress values to catch up with new targets (smoothing time constant). */
    private static final float SMOOTH_TAU = 1.2f;

    private static final String U_ENABLED   = "BodyShapeEnabled";
    private static final String U_LACTATION = "LactationProgress";
    private static final String U_PREGNANCY = "PregnancyProgress";

    private static final class Snapshot {
        final IsoGameCharacter target;
        final float lactation;
        final float pregnancy;
        Snapshot(IsoGameCharacter target, float lactation, float pregnancy) {
            this.target = target;
            this.lactation = lactation;
            this.pregnancy = pregnancy;
        }
    }

    // ---- avatar patch controls ----
    /** Off by default: UpdateCharacter is a riskier hook point. Switched on from Lua. */
    private static volatile boolean avatarEnabled = false;
    /** Tests only: non-null forces the "is a GL context current?" answer. */
    public static volatile Boolean glContextOverride = null;
    private static java.lang.reflect.Method glCaps;
    private static boolean glCapsResolved;
    private static volatile long avatarSkippedNoContext;
    // tracer: basicEffect draws (Start..End) that never passed through Shader.startCharacter
    private static boolean sawStartThisDraw;            // render thread only
    private static volatile long noStartDraws;
    private static volatile int noStartLogged;
    // what Shader.startCharacter was handed (logged once per kind, no per-frame allocation)
    private static volatile boolean seenNullSlot, seenNullChar, seenTargetChar;
    private static final java.util.Set<Class<?>> seenCharClasses =
            java.util.Collections.newSetFromMap(new java.util.concurrent.ConcurrentHashMap<Class<?>, Boolean>());

    // game thread writes, render thread reads
    private static volatile Snapshot snapshot = new Snapshot(null, 0f, 0f);

    // render thread only
    private static IsoGameCharacter smoothedFor;
    private static float curLactation, curPregnancy;
    private static long lastNanos;

    // diagnostics (render thread writes, anything reads)
    private static volatile long shaderCalls, matchedCalls, setCalls;
    private static volatile String lastShader = "(none yet)";
    private static volatile long avatarCalls, avatarMatched;
    private static volatile String lastAvatar = "(none yet)";
    private static volatile float shownLact, shownPreg;   // what was last written for the target
    private static volatile boolean failed;
    private static volatile String failure = "";
    private static final java.util.Set<String> seenShaders =
            java.util.Collections.synchronizedSet(new java.util.LinkedHashSet<>());

    private BodyShapeState() {}

    private static float clamp(double v, double lo, double hi) {
        if (v != v) return 0f;                 // NaN
        return (float) Math.max(lo, Math.min(hi, v));
    }

    /** Lactation is a CHEST SIZE FACTOR: 0 = basicEffect chest, 1 = more_feminime, up to 3 (sandbox). */
    public static final float MAX_LACTATION = 3f;

    // ------------------------------------------------------------------ game thread

    /** @param chr character to shape, or null/enabled=false for "nobody". */
    public static void set(IsoGameCharacter chr, boolean enabled, double lactation, double pregnancy) {
        setCalls++;
        if (!enabled || chr == null) {
            snapshot = new Snapshot(null, 0f, 0f);
        } else {
            snapshot = new Snapshot(chr, clamp(lactation, 0.0, MAX_LACTATION), clamp(pregnancy, 0.0, 1.0));
        }
    }

    public static void setAvatarEnabled(boolean on) {
        avatarEnabled = on;
        System.out.println("[BodyShapeHook] avatar (UpdateCharacter) path " + (on ? "ENABLED" : "disabled"));
    }

    private static boolean avatarPatchPresent() {
        try { Class.forName("com.bfbodyshape.AvatarUpdateCharacterPatch"); return true; }
        catch (Throwable t) { return false; }
    }

    public static String status() {
        Snapshot s = snapshot;
        return "BodyShapeHook: setCalls=" + setCalls
                + " target=" + (s.target == null ? "none" : s.target.getClass().getSimpleName())
                + " lact=" + s.lactation + " preg=" + s.pregnancy
                + " | rendered lact=" + shownLact + " preg=" + shownPreg
                + " | world: calls=" + shaderCalls + " matched=" + matchedCalls + " noStartDraws=" + noStartDraws
                + " kinds[nullSlot=" + seenNullSlot + " nullChar=" + seenNullChar + " target=" + seenTargetChar
                + " classes=" + seenCharClasses.size() + "]"
                + " | avatar: patchCompiled=" + avatarPatchPresent() + " enabled=" + avatarEnabled
                + " skippedNoGL=" + avatarSkippedNoContext + " calls=" + avatarCalls + " matched=" + avatarMatched + " lastChar=" + lastAvatar
                + " lastShader=" + lastShader + " seenShaders=" + seenShaders
                + (failed ? " | FAILED: " + failure : "");
    }

    // ------------------------------------------------------------------ render thread

    private static boolean isBodyShader(Shader shader) {
        if (shader == null) return false;
        String name = shader.getName();
        if (name != null && seenShaders.size() < 16 && seenShaders.add(name + (shader.isInstanced() ? "(instanced)" : ""))) {
            System.out.println("[BodyShapeHook] saw shader '" + name + "' static=" + shader.isStatic()
                    + " instanced=" + shader.isInstanced());
        }
        lastShader = String.valueOf(name);
        // Per-model uniforms cannot work on the instanced path (data comes from a shared buffer).
        return SHADER_NAME.equals(name) && !shader.isStatic() && !shader.isInstanced();
    }

    private static void smooth(Snapshot s) {
        long now = System.nanoTime();
        if (s.target != smoothedFor) {            // new target (load / respawn): snap, no pop
            smoothedFor = s.target;
            curLactation = s.lactation;
            curPregnancy = s.pregnancy;
            lastNanos = now;
            return;
        }
        float dt = (now - lastNanos) / 1.0e9f;
        if (dt <= 0f) return;
        lastNanos = now;
        if (dt > 0.25f) dt = 0.25f;               // long frame / pause: don't overshoot
        float a = 1f - (float) Math.exp(-dt / SMOOTH_TAU);   // composes correctly over many calls
        curLactation += (s.lactation - curLactation) * a;
        curPregnancy += (s.pregnancy - curPregnancy) * a;
    }

    private static void write(Shader shader, float enabled, float lact, float preg) {
        ShaderProgram sp = shader.getShaderProgram();
        sp.setValue(U_ENABLED, enabled);
        sp.setValue(U_LACTATION, lact);
        sp.setValue(U_PREGNANCY, preg);
    }

    /** Writes the three uniforms for one draw; program must be bound. */
    private static void applyIf(Shader shader, Snapshot s, boolean on) {
        if (on) {
            smooth(s);
            shownLact = curLactation;
            shownPreg = curPregnancy;
            write(shader, 1f, curLactation, curPregnancy);
        } else {
            write(shader, 0f, 0f, 0f);
        }
    }

    private static void noteSlotKind(ModelSlotRenderData slot, Snapshot s) {
        if (slot == null) {
            if (!seenNullSlot) { seenNullSlot = true; System.out.println("[BodyShapeHook] startCharacter saw: slot=null"); }
        } else if (slot.character == null) {
            if (!seenNullChar) { seenNullChar = true; System.out.println("[BodyShapeHook] startCharacter saw: slot.character=null (possible UI avatar)"); }
        } else if (slot.character == s.target) {
            if (!seenTargetChar) { seenTargetChar = true; System.out.println("[BodyShapeHook] startCharacter saw: the TARGET player"); }
        } else if (seenCharClasses.add(slot.character.getClass())) {
            System.out.println("[BodyShapeHook] startCharacter saw: " + slot.character.getClass().getSimpleName() + " (not target)");
        }
    }

    /** Called right after Shader.startCharacter(slotData, instData) - program is bound. */
    public static void applyTo(Shader shader, ModelSlotRenderData slot) {
        if (failed) return;
        try {
            if (!isBodyShader(shader)) return;
            sawStartThisDraw = true;
            shaderCalls++;
            Snapshot s = snapshot;
            noteSlotKind(slot, s);
            boolean on = s.target != null && slot != null && slot.character == s.target;
            if (on) matchedCalls++;
            applyIf(shader, s, on);
        } catch (Throwable t) {
            fail(t);
        }
    }

    /**
     * True only when an OpenGL context is current on THIS thread. Writing a uniform without
     * one crashes the JVM natively (no Java exception, no log) - exactly the failure mode
     * we must never risk. Resolved by reflection so the build has no LWJGL dependency.
     * If it cannot be determined the answer is false (feature stays inactive).
     */
    private static boolean hasGlContext() {
        Boolean forced = glContextOverride;
        if (forced != null) return forced;
        if (!glCapsResolved) {
            glCapsResolved = true;
            for (String cn : new String[] { "org.lwjgl.opengl.GL", "org.lwjgl.opengl.GLContext" }) {
                try { glCaps = Class.forName(cn).getMethod("getCapabilities"); break; }
                catch (Throwable ignored) { }
            }
            if (glCaps == null) System.out.println("[BodyShapeHook] cannot verify GL context (no LWJGL GL class found): avatar path stays inactive");
        }
        if (glCaps == null) return false;
        try { return glCaps.invoke(null) != null; }
        catch (Throwable t) { return false; }   // IllegalStateException: no current context
    }

    /**
     * UI avatars (health panel paper doll) never go through startCharacter; they call
     * AnimatedModelInstanceRenderData.UpdateCharacter(Shader) directly.
     *
     * @param worldPath true when the render data is the world-render subclass
     *        (ModelInstanceRenderData). There only an EXACT character match counts, so a
     *        zombie's clothing with an unset character can never pick up the shape.
     *        On the pure UI path a model instance with no character is treated as the
     *        player's own avatar (see AVATAR_NULL_CHARACTER_MATCHES).
     */
    public static void applyToAvatar(Shader shader, ModelInstance mi, boolean worldPath) {
        if (failed || !avatarEnabled) return;
        if (worldPath) return;   // world draws are fully handled by Shader.startCharacter
        try {
            if (!isBodyShader(shader)) return;
            if (!hasGlContext()) { avatarSkippedNoContext++; return; }
            avatarCalls++;
            Snapshot s = snapshot;
            IsoGameCharacter c = mi == null ? null : mi.character;
            if (c == null && mi != null && mi.parent != null) c = mi.parent.character;

            boolean exact = s.target != null && c == s.target;
            boolean nullMatch = s.target != null && c == null && !worldPath && AVATAR_NULL_CHARACTER_MATCHES;
            boolean on = exact || nullMatch;

            String desc = (worldPath ? "world:" : "ui:")
                    + (c == null ? "null" : (c == s.target ? "target" : c.getClass().getSimpleName()));
            if (!desc.equals(lastAvatar)) {
                lastAvatar = desc;
                System.out.println("[BodyShapeHook] UpdateCharacter path saw " + desc + " -> " + (on ? "SHAPED" : "vanilla"));
            }
            if (on) avatarMatched++;
            applyIf(shader, s, on);
        } catch (Throwable t) {
            fail(t);
        }
    }

    /**
     * Called at the start of Shader.End() - program still bound. Clears our uniforms for the next
     * draw and, as a diagnostic, notes basicEffect draws that never went through startCharacter
     * (e.g. UI avatars) together with the caller's stack. No GL work is added by the tracer.
     */
    public static void reset(Shader shader) {
        if (failed) return;
        try {
            if (shader != null && SHADER_NAME.equals(shader.getName()) && !shader.isStatic() && !shader.isInstanced()) {
                write(shader, 0f, 0f, 0f);
                if (!sawStartThisDraw) noteNoStartDraw();
                sawStartThisDraw = false;
            }
        } catch (Throwable t) {
            fail(t);
        }
    }

    private static void noteNoStartDraw() {
        noStartDraws++;
        if (noStartLogged >= 3) return;                   // stacks are only needed a few times
        noStartLogged++;
        StringBuilder sb = new StringBuilder();
        int n = 0;
        for (StackTraceElement e : new Throwable().getStackTrace()) {
            String c = e.getClassName();
            if (c.startsWith("com.bfbodyshape")) continue; // skip our own frames
            sb.append("\n      at ").append(c).append('.').append(e.getMethodName()).append(':').append(e.getLineNumber());
            if (++n >= 14) break;
        }
        System.out.println("[BodyShapeHook] basicEffect drawn WITHOUT Shader.startCharacter (#" + noStartDraws
                + ") - caller stack:" + sb);
    }

    private static void fail(Throwable t) {
        failed = true;                            // stop touching the renderer after the first error
        failure = t.toString();
        System.out.println("[BodyShapeHook] disabled after error: " + t);
        t.printStackTrace(System.out);
    }
}
