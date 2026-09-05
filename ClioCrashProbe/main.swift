import Darwin

// This executable is a test dependency only, never part of Clio.app.
#if DEBUG
CrashTestDriver.runIfRequested()
#endif
_exit(93)
