package com.EDI.ZDT_HS.inference;

public class ModelRetiredException extends RuntimeException {

    private final String retiredVersion;
    private final String currentVersion;

    public ModelRetiredException(String retiredVersion, String currentVersion) {
        super("Model version " + retiredVersion + " was retired during request");
        this.retiredVersion = retiredVersion;
        this.currentVersion = currentVersion;
    }

    public String getRetiredVersion()  { return retiredVersion; }
    public String getCurrentVersion()  { return currentVersion; }
}