// Decompile every function that references a string containing one of the given substrings.
// Usage (headless postScript): DecompileByString.java <outfile> <substr1> [substr2 ...]
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;
import java.io.*;
import java.util.*;

public class DecompileByString extends GhidraScript {
    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(args[0]));
        Memory mem = currentProgram.getMemory();
        Listing listing = currentProgram.getListing();
        ReferenceManager refs = currentProgram.getReferenceManager();
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        Set<Function> done = new LinkedHashSet<>();
        for (int a = 1; a < args.length; a++) {
            if (args[a].startsWith("@")) {   // "@0x1234": decompile the function at that address
                Address at = toAddr(Long.decode(args[a].substring(1)));
                Function f = listing.getFunctionContaining(at);
                if (f == null) f = createFunction(at, null);
                if (f != null) done.add(f); else out.printf("== no function at %s%n", at);
                continue;
            }
            byte[] pat = args[a].getBytes("ISO-8859-1");
            Address hit = mem.findBytes(currentProgram.getMinAddress(), pat, null, true, monitor);
            while (hit != null) {
                // walk back to the start of the C string
                Address start = hit;
                while (start.getOffset() > 0) {
                    byte b = mem.getByte(start.subtract(1));
                    if (b == 0 || b == '\n') break;
                    start = start.subtract(1);
                }
                out.printf("== string \"%s\" at %s (starts %s)%n", args[a], hit, start);
                for (Address cand : new Address[] { start, hit }) {
                    for (Reference r : refs.getReferencesTo(cand)) {
                        Function f = listing.getFunctionContaining(r.getFromAddress());
                        out.printf("   ref from %s in %s%n", r.getFromAddress(), f == null ? "?" : f.getName() + "@" + f.getEntryPoint());
                        if (f != null) done.add(f);
                    }
                }
                hit = mem.findBytes(hit.add(1), pat, null, true, monitor);
            }
        }
        for (Function f : done) {
            DecompileResults res = di.decompileFunction(f, 60, monitor);
            out.printf("%n/* ===== %s @ %s ===== */%n", f.getName(), f.getEntryPoint());
            out.println(res.decompileCompleted() ? res.getDecompiledFunction().getC() : "/* decompile failed: " + res.getErrorMessage() + " */");
        }
        out.close();
    }
}
