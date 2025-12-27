const os = require('os');

module.exports = require('./NullService');

// Check macOS version >= 16.1.0 (Sierra 10.12+) without semver
function isMinMacOSVersion(minMajor, minMinor) {
  const [major, minor] = os.release().split('.').map(Number);
  return major > minMajor || (major === minMajor && minor >= minMinor);
}

switch (process.platform) {
  case 'darwin': {
    if (isMinMacOSVersion(16, 1)) {
      module.exports = require('./darwin');
    }
    break;
  }
  default: {
    break;
  }
}
