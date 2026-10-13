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
    screenOff: {
      ac: { afterMinutes: 0 },
      batteryHigh: { afterMinutes: 0 },
      batteryLow: { afterMinutes: 0 }
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
