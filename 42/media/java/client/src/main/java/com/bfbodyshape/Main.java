package com.bfbodyshape;

/** Optional entry point: ZombieBuddy runs main() when the mod loads. Patches apply regardless. */
public class Main {
    public static void main(String[] args) {
        System.out.println("[BodyShapeHook] loaded (class loader: " + Main.class.getClassLoader() + ")");
    }
}
