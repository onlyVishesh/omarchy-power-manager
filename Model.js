// Model.js — Power Manager helpers

function defaultConfig() {
  return {
    version: 1,
    enabled: true,
    batteryThreshold: 20,
    profiles: {
      ac: "performance",
      batteryHigh: "balanced",
      batteryLow: "power-saver"
    },
    brightness: {
      auto: false,
      ac: 80,
      batteryHigh: 50,
      batteryLow: 30
    },
    idle: {
      ac: {
        sleepAfterMinutes: 30,
        afterSleep: "suspend",
        hibernateAfterMinutes: 60
      },
      batteryHigh: {
        sleepAfterMinutes: 15,
        afterSleep: "suspend",
        hibernateAfterMinutes: 30
      },
      batteryLow: {
        sleepAfterMinutes: 5,
        afterSleep: "suspend",
        hibernateAfterMinutes: 15
      }
    },
    lid: {
      ignoreLidClose: false,
      ac: { action: "suspend" },
      batteryHigh: { action: "suspend" },
      batteryLow: { action: "suspend" }
    },
    appearance: {
      showPercentage: true
    },
    notifications: {
      profileChanges: true,
      thresholdCrossing: true,
      hibernationWarning: true
    }
  };
}

function deepMerge(target, source) {
  if (!source || typeof source !== 'object') return target;
  var result = {};
  var keys = Object.keys(target);
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    if (source.hasOwnProperty(k)) {
      if (target[k] && typeof target[k] === 'object' && !Array.isArray(target[k])
          && source[k] && typeof source[k] === 'object' && !Array.isArray(source[k])) {
        result[k] = deepMerge(target[k], source[k]);
      } else {
        result[k] = source[k];
      }
    } else {
      result[k] = target[k];
    }
  }
  var srcKeys = Object.keys(source);
  for (var j = 0; j < srcKeys.length; j++) {
    if (!target.hasOwnProperty(srcKeys[j])) {
      result[srcKeys[j]] = source[srcKeys[j]];
    }
  }
  return result;
}

function mergeWithDefaults(config) {
  return deepMerge(defaultConfig(), config || {});
}

function validateConfig(config) {
  var errors = [];
  if (!config) return { valid: false, errors: ["Config is null"] };
  if (config.batteryThreshold && (config.batteryThreshold < 5 || config.batteryThreshold > 95)) {
    errors.push("Battery threshold must be between 5 and 95");
  }
  return { valid: errors.length === 0, errors: errors };
}

function batteryFraction(device) {
  return device && device.isPresent ? Math.max(0, Math.min(1, device.percentage)) : 0;
}

function chargeThresholdActive(device, onBattery, states) {
  var d = device || {};
  var s = states || {};
  if (!d.isPresent || onBattery) return false;
  var fraction = batteryFraction(d);
  if (d.state === s.Discharging) return false;
  if (d.state === s.PendingCharge) return true;
  if (d.state === s.FullyCharged && fraction < 0.99) return true;
  if (d.state !== s.Charging || fraction >= 0.99) return false;
  return false;
}

function batteryIcon(device, onBattery, states) {
  var d = device || {};
  if (!d.isPresent) return "";
  var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"];
  var defaultIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"];
  var index = Math.max(0, Math.min(9, Math.floor(batteryFraction(d) * 10)));
  var threshold = chargeThresholdActive(d, onBattery, states);
  if (threshold) return defaultIcons[index];
  if (d.state === states.FullyCharged) return "󰂅";
  if (!onBattery) return chargingIcons[index];
  return defaultIcons[index];
}

// ── Multi-battery aggregation ──
// Laptops such as the ThinkPad T470 expose two battery devices (internal +
// removable). Every calculation here works on the combined packs, weighted by
// their actual energy/charge capacity, so 5% + 9% is reported as ~8% and not
// as whichever battery happened to be listed first.

var MICRO = 1000000;

function batteryNum(row, key) {
  var n = parseInt(row[key], 10);
  return isNaN(n) ? -1 : n;
}

function parseBatteryProbe(raw) {
  var rows = [];
  var cur = null;
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    if (line.indexOf("battery=") === 0) {
      if (cur) rows.push(cur);
      cur = { path: line.slice(8) };
    } else if (line === "end") {
      if (cur) { rows.push(cur); cur = null; }
    } else if (cur) {
      var eq = line.indexOf("=");
      if (eq > 0) cur[line.slice(0, eq)] = line.slice(eq + 1).trim();
    }
  }
  if (cur) rows.push(cur);
  return rows;
}

function combineBatteryStatus(statuses, allFull) {
  if (!statuses || statuses.length === 0) return "Unknown";
  if (allFull) return "Full";
  for (var i = 0; i < statuses.length; i++) if (statuses[i] === "charging") return "Charging";
  for (var j = 0; j < statuses.length; j++) if (statuses[j] === "discharging") return "Discharging";
  for (var k = 0; k < statuses.length; k++) if (statuses[k] === "not charging") return "Not charging";
  return statuses[0].charAt(0).toUpperCase() + statuses[0].slice(1);
}

function aggregateBatteries(rows, validPath) {
  var out = {
    batteryCount: 0,
    batteryPaths: [],
    limitPaths: [],
    present: false,
    capacity: -1,
    status: "",
    cycleCount: -1,
    full: -1,
    fullDesign: -1,
    capacityUnit: "Wh",
    healthPct: -1,
    supported: false,
    limit: 100,
    limitUniform: true
  };
  if (!rows || rows.length === 0) return out;

  var whNow = 0, whFull = 0, whDesign = 0, whOk = true;
  var ahNow = 0, ahFull = 0, ahDesign = 0, ahOk = true;
  var designKnown = true;
  var capSum = 0, capCount = 0;
  var cycles = 0, cyclesKnown = 0;
  var statuses = [];
  var limitVals = [];
  var allFull = true;

  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    if (!r || !r.path) continue;
    if (validPath && !validPath(r.path)) continue;
    if (batteryNum(r, "present") === 0) continue;
    // Ignore non-battery supplies (mains, USB-C, etc.) defensively.
    if (r.capacity === undefined && r.energy_full === undefined && r.charge_full === undefined) continue;

    out.batteryCount++;
    out.batteryPaths.push(r.path);

    var eNow = batteryNum(r, "energy_now");
    var eFull = batteryNum(r, "energy_full");
    var eDesign = batteryNum(r, "energy_full_design");
    var cNow = batteryNum(r, "charge_now");
    var cFull = batteryNum(r, "charge_full");
    var cDesign = batteryNum(r, "charge_full_design");
    var volt = batteryNum(r, "voltage_now");

    var rowWh = false;
    if (eFull > 0 && eNow >= 0) {
      whNow += eNow / MICRO;
      whFull += eFull / MICRO;
      if (eDesign > 0) {
        whDesign += eDesign / MICRO;
      } else {
        whDesign += eFull / MICRO;
        designKnown = false;
      }
      rowWh = true;
    } else if (cFull > 0 && cNow >= 0 && volt > 0) {
      whNow += cNow * volt / 1e12;
      whFull += cFull * volt / 1e12;
      if (cDesign > 0) {
        whDesign += cDesign * volt / 1e12;
      } else {
        whDesign += cFull * volt / 1e12;
        designKnown = false;
      }
      rowWh = true;
    }
    if (!rowWh) whOk = false;

    if (cFull > 0 && cNow >= 0) {
      ahNow += cNow / MICRO;
      ahFull += cFull / MICRO;
      if (cDesign > 0) {
        ahDesign += cDesign / MICRO;
      } else {
        ahDesign += cFull / MICRO;
        designKnown = false;
      }
    } else {
      ahOk = false;
    }

    var cap = batteryNum(r, "capacity");
    if (cap >= 0) { capSum += cap; capCount++; }

    var cyc = batteryNum(r, "cycle_count");
    if (cyc >= 0) { cycles += cyc; cyclesKnown++; }

    var st = String(r.status || "").toLowerCase();
    if (st) {
      statuses.push(st);
      if (st !== "full") allFull = false;
    } else {
      allFull = false;
    }

    if (r.charge_control_end_threshold !== undefined) {
      var lim = batteryNum(r, "charge_control_end_threshold");
      if (lim >= 1 && lim <= 100) {
        limitVals.push(lim);
        out.limitPaths.push(r.path);
      }
    }
  }

  out.present = out.batteryCount > 0;
  out.supported = out.limitPaths.length > 0;
  if (out.supported) {
    var minLimit = 100;
    for (var l = 0; l < limitVals.length; l++) {
      if (limitVals[l] < minLimit) minLimit = limitVals[l];
      if (limitVals[l] !== limitVals[0]) out.limitUniform = false;
    }
    out.limit = minLimit;
  }

  if (out.batteryCount > 0) {
    // Prefer energy (Wh). Fall back to charge (Ah), then to the simple
    // capacity average only when the kernel exposes no usable totals.
    if (whOk && whFull > 0) {
      out.full = whFull;
      out.fullDesign = whDesign > 0 ? whDesign : whFull;
      out.capacityUnit = "Wh";
      out.capacity = Math.max(0, Math.min(100, Math.round(whNow / whFull * 100)));
    } else if (ahOk && ahFull > 0) {
      out.full = ahFull;
      out.fullDesign = ahDesign > 0 ? ahDesign : ahFull;
      out.capacityUnit = "Ah";
      out.capacity = Math.max(0, Math.min(100, Math.round(ahNow / ahFull * 100)));
    } else if (capCount > 0) {
      out.capacity = Math.max(0, Math.min(100, Math.round(capSum / capCount)));
    }

    if (designKnown && out.full > 0 && out.fullDesign > 0) out.healthPct = out.full / out.fullDesign * 100;
    if (cyclesKnown > 0) out.cycleCount = cycles;
    out.status = combineBatteryStatus(statuses, allFull);
  }
  return out;
}

function formatTime(seconds) {
  var s = Number(seconds);
  if (!(s > 0) || !isFinite(s)) return "—";
  var mins = Math.round(s / 60);
  if (mins < 1) return "<1m";
  if (mins < 60) return mins + "m";
  var h = Math.floor(mins / 60);
  var m = mins % 60;
  return m > 0 ? h + "h " + m + "m" : h + "h";
}

function formatEnergy(wh) {
  var v = Number(wh);
  if (!(v > 0) || !isFinite(v)) return "—";
  return (v >= 10 ? Math.round(v) : Math.round(v * 10) / 10) + " Wh";
}

function formatRate(watts) {
  var w = Math.abs(Number(watts));
  if (!(w > 0) || !isFinite(w)) return "0W";
  return Math.round(w * 10) / 10 + "W";
}

function modeLabel(device, onBattery, states) {
  var d = device || {};
  if (!d.isPresent) return "";
  var fraction = batteryFraction(d);
  if (chargeThresholdActive(d, onBattery, states)) return "Threshold";
  if (onBattery) return "On battery";
  if (!onBattery && fraction >= 1) return "Fully charged";
  return "Charging";
}

function clampIndex(idx, len) {
  if (len === 0) return 0;
  if (idx < 0) return 0;
  if (idx >= len) return len - 1;
  return idx;
}

function parseProfiles(raw, previousIndex) {
  var lines = String(raw || "").split("\n");
  var list = [];
  var active = "";
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim();
    if (!line) continue;
    var parts = line.split("\t");
    list.push(parts[0]);
    if (parts[1] === "1") active = parts[0];
  }
  return {
    profiles: list,
    activeProfile: active,
    profileIndex: clampIndex(previousIndex || 0, list.length)
  };
}

function selectProfileIndex(current, delta, profiles) {
  if (!profiles || profiles.length === 0) return 0;
  var next = current + delta;
  return clampIndex(next, profiles.length);
}

function profileIcon(name) {
  if (name === "power-saver") return "󰌪";
  if (name === "balanced") return "󰊚";
  if (name === "performance") return "󰓅";
  return "󰂄";
}

function parseKeyValue(raw) {
  var next = {};
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    var idx = lines[i].indexOf("\t");
    if (idx <= 0) continue;
    next[lines[i].substring(0, idx)] = lines[i].substring(idx + 1).trim();
  }
  return next;
}

function hibernationReady(diag) {
  if (!diag || typeof diag !== 'object') return false;
  var swap = diag.swap || {};
  var resume = diag.resume || {};
  var initramfs = diag.initramfs || {};
  return !!(swap.adequate_for_hibernate
    && diag.hibernate_available
    && resume.kernel_cmdline_has_resume
    && initramfs.resume_hook_present
    && initramfs.hook_order_correct);
}

function hibernationIssues(diag) {
  if (!diag || typeof diag !== 'object') return ["Diagnostics not loaded"];
  var issues = [];
  var swap = diag.swap || {};
  var resume = diag.resume || {};
  var initramfs = diag.initramfs || {};
  if (!swap.adequate_for_hibernate) issues.push("Swap insufficient for hibernation");
  if (!diag.hibernate_available) issues.push("Hibernate service not available");
  if (!resume.kernel_cmdline_has_resume) issues.push("Missing resume= in kernel cmdline");
  if (!initramfs.resume_hook_present) issues.push("Resume hook not in initramfs");
  if (!initramfs.hook_order_correct) issues.push("Initramfs hook order incorrect");
  return issues;
}
