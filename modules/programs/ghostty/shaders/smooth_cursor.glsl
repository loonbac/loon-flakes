// Smooth Cursor Movement Shader for Ghostty Terminal
// Easing animation for cursor movement (vertical line jumps, horizontal navigation, history, etc.)

#define ANIMATION_DURATION 0.12  // Animación rápida (120 ms)
#define TRAIL_STRENGTH 0.30      // Estela suave e imperceptible
#define CORNER_RADIUS 2.0        // Radio de redondeo de bordes (píxeles)

// Ease-out cúbico (movimiento ágil y frenado suave)
float easeOutCubic(float x) {
    float f = 1.0 - x;
    return 1.0 - f * f * f;
}

// Distance Field (SDF) para el rectángulo con bordes redondeados
float sdRoundedBox(in vec2 p, in vec2 b, in float r) {
    vec2 q = abs(p) - b + vec2(r);
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    // 1. Obtener la textura renderizada por el terminal
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminalColor = texture(iChannel0, uv);

    // Si el cursor no está visible o no hay cambio, retornar la textura base
    if (iCursorVisible == 0) {
        fragColor = terminalColor;
        return;
    }

    // 2. Tiempo transcurrido desde el último movimiento
    float timeSinceMove = iTime - iTimeCursorChange;
    
    // Si la animación ya concluyó (120ms), mostrar la terminal normal
    if (timeSinceMove >= ANIMATION_DURATION) {
        fragColor = terminalColor;
        return;
    }

    // 3. Normalización del tiempo de animación [0.0 - 1.0]
    float progress = clamp(timeSinceMove / ANIMATION_DURATION, 0.0, 1.0);
    float t = easeOutCubic(progress);

    // 4. Posiciones y dimensiones en píxeles (Ghostty pasa coordenadas top-down)
    vec2 prevPos = iPreviousCursor.xy;
    vec2 prevSize = iPreviousCursor.zw;
    vec2 currPos = iCurrentCursor.xy;
    vec2 currSize = iCurrentCursor.zw;

    float moveDist = length(currPos - prevPos);

    // Si el cursor no se movió de posición, no dibujamos animación sobrepuesta
    if (moveDist < 0.5) {
        fragColor = terminalColor;
        return;
    }

    // 5. Interpolar la posición y tamaño del cursor animado en el tiempo t
    vec2 animPos = mix(prevPos, currPos, t);
    vec2 animSize = mix(prevSize, currSize, t);

    // 6. Color del cursor (fallback si el alfa no está definido)
    vec4 cursorColor = iCurrentCursorColor;
    if (cursorColor.a < 0.05) {
        cursorColor = vec4(0.8, 0.85, 0.95, 0.85);
    }

    // 7. Render del bloque animado del cursor
    vec2 animCenter = animPos + animSize * 0.5;
    vec2 p = fragCoord - animCenter;
    vec2 halfSize = animSize * 0.5;

    float dist = sdRoundedBox(p, halfSize, CORNER_RADIUS);
    float cursorMask = 1.0 - smoothstep(-0.5, 0.5, dist);

    // 8. Dibujo de la estela sutil (trail) a lo largo del trayecto de desplazamiento
    float trailMask = 0.0;
    if (TRAIL_STRENGTH > 0.0 && moveDist > 3.0) {
        vec2 pPrevCenter = prevPos + prevSize * 0.5;
        vec2 pCurrCenter = currPos + currSize * 0.5;
        
        vec2 pa = fragCoord - pPrevCenter;
        vec2 ba = pCurrCenter - pPrevCenter;
        float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        vec2 lineVec = pa - ba * h;
        float lineDist = length(lineVec);

        // La estela conecta desde la posición inicial hasta la posición actual en el tiempo t
        if (h <= t) {
            float trailWidth = min(animSize.x, animSize.y) * 0.35;
            float lineAlpha = 1.0 - smoothstep(0.0, trailWidth, lineDist);
            float fadeFactor = (1.0 - progress) * TRAIL_STRENGTH;
            trailMask = lineAlpha * fadeFactor;
        }
    }

    // Combinar el cursor desplazándose y su estela
    float totalAlpha = clamp(cursorMask + trailMask, 0.0, 1.0);

    // Mezclar el cursor animado con el contenido de la terminal
    vec3 finalRGB = mix(terminalColor.rgb, cursorColor.rgb, totalAlpha * 0.80);

    fragColor = vec4(finalRGB, terminalColor.a);
}
