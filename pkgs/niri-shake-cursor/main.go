package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Linux input event constants
const (
	evRel = 0x02
	relX  = 0x00

	// Touchpad: eventos absolutos de posición del dedo (ABS_MT).
	evAbs       = 0x03
	absMtPosX   = 0x35 // ABS_MT_POSITION_X (53)
	absMtSlot   = 0x2f // ABS_MT_SLOT (47) — para distinguir dedos
	absTracking = 0x39 // ABS_MT_TRACKING_ID (57) — -1 = dedo levantado
)

// inputEvent mirrors the Linux struct input_event (64-bit).
type inputEvent struct {
	TimeSec  int64
	TimeUsec int64
	Type     uint16
	Code     uint16
	Value    int32
}

// motionSample records a single X-axis movement with its timestamp.
type motionSample struct {
	t  time.Time
	dx int32
}

// Shake detection parameters.
// Tune these to adjust sensitivity.
const (
	shakeWindow    = 600 * time.Millisecond // sliding window for detecting reversals
	minReversals   = 3                      // minimum direction changes to qualify as a shake
	minTotalDist   = 200                    // minimum cumulative |dx| in the window
	minSegmentDist = 20                     // minimum distance in one direction before counting a reversal
)

// Temas de cursor: el normal y el "grow" (animado, crece).
const (
	normalTheme = "Win11OSX"
	growTheme   = "Win11OSX-Grow"
	bigTheme    = "Win11OSX-Big"
)

// Duración de la animación de crecimiento (la del cursor grow, 12 frames
// a 40ms ≈ 480ms) antes de pasar al cursor estático grande.
const growAnimDuration = 600 * time.Millisecond

// How long the cursor stays big after the last shake
const shrinkDelay = 2 * time.Second

func main() {
	log.SetFlags(log.Ltime)

	configPath := findNiriCursorConfig()
	if configPath == "" {
		log.Fatal("Could not find niri cursor config. " +
			"Make sure your niri config contains an 'xcursor-size' setting.")
	}
	log.Printf("Using config file: %s", configPath)

	devices := findMouseDevices()
	if len(devices) == 0 {
		log.Fatal("Could not find any mouse/pointer input devices. " +
			"Make sure your user is in the 'input' group: sudo usermod -aG input $USER")
	}

	// Open all pointing devices
	var files []*os.File
	for _, dev := range devices {
		f, err := os.Open(dev)
		if err != nil {
			log.Printf("Warning: failed to open %s: %v", dev, err)
			continue
		}
		files = append(files, f)
		log.Printf("Listening on: %s", dev)
	}
	if len(files) == 0 {
		log.Fatal("Could not open any input devices. " +
			"Try: sudo usermod -aG input $USER  (then log out and back in)")
	}
	defer func() {
		for _, f := range files {
			f.Close()
		}
	}()

	// Handle clean shutdown: restore normal cursor
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down, restoring cursor...")
		setCursorTheme(configPath, normalTheme)
		os.Exit(0)
	}()

	var (
		samples  []motionSample
		enlarged bool
		shrinkAt time.Time
		bigAt    time.Time // cuándo pasar del grow (animación) al big (estático)
	)

	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	// Channel for events from all devices
	evCh := make(chan inputEvent, 256)

	// Start a reader goroutine for each device
	for _, f := range files {
		go readEvents(f, evCh)
	}

	for {
		select {
		case ev := <-evCh:
			now := time.Now()
			samples = append(samples, motionSample{t: now, dx: ev.Value})

			// Prune old samples outside the sliding window
			cutoff := now.Add(-shakeWindow)
			for len(samples) > 0 && samples[0].t.Before(cutoff) {
				samples = samples[1:]
			}

			// Count reversals and total distance in the window
			reversals, totalDist := analyzeShake(samples)

			if reversals >= minReversals && totalDist >= minTotalDist {
				shrinkAt = now.Add(shrinkDelay)
				if !enlarged {
					enlarged = true
					log.Println("Shake detected! Playing grow animation.")
					bigAt = now.Add(growAnimDuration)
					setCursorTheme(configPath, growTheme)
				}
			}

		case <-ticker.C:
			now := time.Now()
			if enlarged && !bigAt.IsZero() && now.After(bigAt) {
				bigAt = time.Time{}
				log.Println("Grow animation done, staying big.")
				setCursorTheme(configPath, bigTheme)
			}
			if enlarged && now.After(shrinkAt) {
				enlarged = false
				log.Println("Restoring normal cursor.")
				setCursorTheme(configPath, normalTheme)
				samples = samples[:0]
			}
		}
	}
}

// readEvents continuously reads input events from a device file and sends
// X-axis motion deltas to the provided channel. Soporta:
//   - Mice: REL_X (delta directo).
//   - Trackpad: ABS_MT_POSITION_X (posición absoluta del dedo; el delta se
//     calcula restando la posición anterior del mismo slot).
func readEvents(f *os.File, ch chan<- inputEvent) {
	buf := make([]byte, 24) // sizeof(struct input_event) on 64-bit Linux

	// Estado del trackpad: última posición X por slot.
	lastPos := make(map[int32]int32)
	curSlot := int32(0)
	hasTouch := false

	for {
		_, err := f.Read(buf)
		if err != nil {
			log.Printf("Read error on %s: %v", f.Name(), err)
			return
		}
		var ev inputEvent
		if err := binary.Read(bytes.NewReader(buf), binary.LittleEndian, &ev); err != nil {
			continue
		}

		if ev.Type == evRel && ev.Code == relX {
			// Mouse: delta directo.
			ch <- ev
			continue
		}

		if ev.Type == evAbs {
			switch ev.Code {
			case absMtSlot:
				curSlot = ev.Value
			case absTracking:
				// -1 = dedo levantado: olvidar su posición.
				if ev.Value == -1 {
					delete(lastPos, curSlot)
					hasTouch = false
				} else {
					hasTouch = true
				}
			case absMtPosX:
				if !hasTouch {
					lastPos[curSlot] = ev.Value
					hasTouch = true
					continue
				}
				prev, ok := lastPos[curSlot]
				if ok {
					dx := ev.Value - prev
					// Solo reportar si el dedo se movió (evita ruido).
					if dx != 0 {
						ch <- inputEvent{Type: evRel, Code: relX, Value: dx}
					}
				}
				lastPos[curSlot] = ev.Value
			}
		}
	}
}

// analyzeShake counts direction reversals and total distance in a slice of
// motion samples. A reversal is counted only when the cumulative distance in
// one direction exceeds minSegmentDist, filtering out small jitter.
func analyzeShake(samples []motionSample) (reversals int, totalDist int32) {
	var (
		lastDir  int32
		segAccum int32
	)
	for _, s := range samples {
		totalDist += abs32(s.dx)
		dir := sign32(s.dx)
		if dir == 0 {
			continue
		}
		if dir == lastDir || lastDir == 0 {
			segAccum += abs32(s.dx)
		} else {
			if segAccum >= minSegmentDist {
				reversals++
			}
			segAccum = abs32(s.dx)
		}
		lastDir = dir
	}
	return
}

// setCursorTheme escribe el override en ~/.config/niri/cursor-size.kdl.
// El config principal de niri (gestionado por NixOS) incluye este archivo;
// niri vigila los includes y recarga la config solo cuando cambia.
func setCursorTheme(configPath string, theme string) {
	content := fmt.Sprintf("cursor {\n    xcursor-theme \"%s\"\n}\n", theme)

	if data, err := os.ReadFile(configPath); err == nil && string(data) == content {
		return
	}

	if err := os.MkdirAll(filepath.Dir(configPath), 0o755); err != nil {
		log.Printf("Failed to create config dir: %v", err)
		return
	}
	if err := os.WriteFile(configPath, []byte(content), 0o644); err != nil {
		log.Printf("Failed to write config: %v", err)
		return
	}
	log.Printf("Wrote cursor theme %s to %s", theme, configPath)
}

// findNiriCursorConfig returns the override file that niri includes.
// El config principal vive en /etc/niri/config.kdl (symlink desde el home),
// gestionado por NixOS; el override editable por el usuario es
// ~/.config/niri/cursor-size.kdl, que el config principal incluye.
func findNiriCursorConfig() string {
	home, _ := os.UserHomeDir()
	p := filepath.Join(home, ".config", "niri", "cursor-size.kdl")
	// El archivo puede no existir aún; devolvemos la ruta de todas formas
	// para que setCursorTheme lo cree.
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return ""
	}
	return p
}

// findMouseDevices returns the paths of all /dev/input/eventX devices that
// can report X motion: relative motion (mice, trackballs) or absolute
// multitouch position (trackpads).
func findMouseDevices() []string {
	entries, err := os.ReadDir("/sys/class/input")
	if err != nil {
		return nil
	}

	var devices []string
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "event") {
			continue
		}

		devPath := filepath.Join("/dev/input", name)

		// Aceptar si reporta movimiento relativo (mice)...
		relPath := filepath.Join("/sys/class/input", name, "device", "capabilities", "rel")
		relData, errRel := os.ReadFile(relPath)
		relOk := errRel == nil && strings.TrimSpace(string(relData)) != "0" && strings.TrimSpace(string(relData)) != ""

		// ...o si es un multitouch (trackpad) con ABS_MT_POSITION_X.
		absPath := filepath.Join("/sys/class/input", name, "device", "capabilities", "abs")
		absData, errAbs := os.ReadFile(absPath)
		// La máscara de capacidades ABS es un hex que representa los códigos
		// ABS soportados (multi-word, little-endian). ABS_MT_POSITION_X = 53.
		absOk := false
		if errAbs == nil {
			words := strings.Fields(strings.TrimSpace(string(absData)))
			var all uint64
			for i := len(words) - 1; i >= 0; i-- {
				v, err := strconv.ParseUint(words[i], 16, 64)
				if err != nil {
					continue
				}
				all = (all << 64) | v
			}
			absOk = (all & (1 << absMtPosX)) != 0
		}

		if !relOk && !absOk {
			continue
		}

		f, err := os.Open(devPath)
		if err != nil {
			continue
		}
		f.Close()

		namePath := filepath.Join("/sys/class/input", name, "device", "name")
		nameData, _ := os.ReadFile(namePath)
		devName := strings.TrimSpace(string(nameData))
		log.Printf("Found pointing device: %s (%s)", devPath, devName)

		devices = append(devices, devPath)
	}

	return devices
}

func sign32(v int32) int32 {
	if v > 0 {
		return 1
	}
	if v < 0 {
		return -1
	}
	return 0
}

func abs32(v int32) int32 {
	if v < 0 {
		return -v
	}
	return v
}
