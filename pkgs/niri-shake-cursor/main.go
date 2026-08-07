package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Linux input event constants
const (
	evRel = 0x02
	relX  = 0x00
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
	shakeWindow    = 500 * time.Millisecond // sliding window for detecting reversals
	minReversals   = 3                      // minimum direction changes to qualify as a shake
	minTotalDist   = 200                    // minimum cumulative |dx| in the window
	minSegmentDist = 30                     // minimum distance in one direction before counting a reversal
)

// Cursor sizes
const (
	normalSize = 32
	largeSize  = 64
)

// How long the cursor stays large after the last shake
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

	// Handle clean shutdown: restore normal cursor size
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("Shutting down, restoring cursor size...")
		setCursorSize(configPath, normalSize)
		os.Exit(0)
	}()

	var (
		samples  []motionSample
		enlarged bool
		shrinkAt time.Time
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
					log.Println("Shake detected! Enlarging cursor.")
					setCursorSize(configPath, largeSize)
				}
			}

		case <-ticker.C:
			if enlarged && time.Now().After(shrinkAt) {
				enlarged = false
				log.Println("Shrinking cursor back to normal.")
				setCursorSize(configPath, normalSize)
				samples = samples[:0]
			}
		}
	}
}

// readEvents continuously reads input events from a device file and sends
// relative X-axis motion events to the provided channel.
func readEvents(f *os.File, ch chan<- inputEvent) {
	buf := make([]byte, 24) // sizeof(struct input_event) on 64-bit Linux
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
			ch <- ev
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

// setCursorSize escribe el override en ~/.config/niri/cursor-size.kdl.
// El config principal de niri (gestionado por NixOS) incluye este archivo;
// niri vigila los includes y recarga la config solo cuando cambia.
func setCursorSize(configPath string, size int) {
	content := fmt.Sprintf("cursor {\n    xcursor-size %d\n}\n", size)

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
	log.Printf("Wrote cursor size %d to %s", size, configPath)
}

// findNiriCursorConfig returns the override file that niri includes.
// El config principal vive en /etc/niri/config.kdl (symlink desde el home),
// gestionado por NixOS; el override editable por el usuario es
// ~/.config/niri/cursor-size.kdl, que el config principal incluye.
func findNiriCursorConfig() string {
	home, _ := os.UserHomeDir()
	p := filepath.Join(home, ".config", "niri", "cursor-size.kdl")
	// El archivo puede no existir aún; devolvemos la ruta de todas formas
	// para que setCursorSize lo cree.
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return ""
	}
	return p
}

// findMouseDevices returns the paths of all /dev/input/eventX devices that
// support relative motion (mice, trackpads, trackballs).
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

		capsPath := filepath.Join("/sys/class/input", name, "device", "capabilities", "rel")
		data, err := os.ReadFile(capsPath)
		if err != nil {
			continue
		}

		relCaps := strings.TrimSpace(string(data))
		if relCaps == "0" || relCaps == "" {
			continue
		}

		devPath := filepath.Join("/dev/input", name)

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
