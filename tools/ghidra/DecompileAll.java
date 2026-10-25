// Decompile every function in the program into one C file.
// Usage (headless postScript): DecompileAll.java <outfile>
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.*;
import java.io.*;

public class DecompileAll extends GhidraScript {
    @Override
    public void run() throws Exception {
        PrintWriter out = new PrintWriter(new FileWriter(getScriptArgs()[0]));
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
            if (monitor.isCancelled()) break;
            DecompileResults res = di.decompileFunction(f, 30, monitor);
            out.printf("%n/* ===== %s @ %s ===== */%n", f.getName(), f.getEntryPoint());
            out.println(res.decompileCompleted() ? res.getDecompiledFunction().getC() : "/* decompile failed */");
        }
        out.close();
    }
}
