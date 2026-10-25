// Decompile functions and their callees (breadth-first, up to a depth) into one C file.
// Callees are taken from the decompiler's CALL ops, following thunks to their targets.
// Usage (headless postScript): DecompileTree.java <outfile> <depth> <addr|name> [addr|name ...]
// Runtime/MFC functions (names containing known prefixes) are listed but not expanded.
import ghidra.app.decompiler.*;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import java.io.*;
import java.util.*;

public class DecompileTree extends GhidraScript {
    private static final String[] SKIP = { "Afx", "afx", "CString", "_RTC_", "__RTC", "_CRT", "__acrt", "___acrt", "__vcrt",
        "___vcrt", "memcpy", "memset", "malloc", "free", "operator", "ATL::", "CWnd", "CObject", "std::", "__security",
        "strlen", "CheckForDebugger", "__chkstk", "_wcs", "_str", "printf", "Mutex" };

    @Override
    public void run() throws Exception {
        String[] a = getScriptArgs();
        PrintWriter out = new PrintWriter(new FileWriter(a[0]));
        int depth = Integer.parseInt(a[1]);
        FunctionManager fm = currentProgram.getFunctionManager();
        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        LinkedHashMap<Function, Integer> seen = new LinkedHashMap<>();
        Map<Function, String> code = new HashMap<>();
        ArrayDeque<Function> queue = new ArrayDeque<>();
        for (int i = 2; i < a.length; i++) {
            Function f = null;
            if (a[i].startsWith("0x")) f = fm.getFunctionContaining(toAddr(Long.decode(a[i])));
            else for (Function g : fm.getFunctions(true)) if (g.getName().equals(a[i])) { f = g; break; }
            if (f == null) { out.println("/* not found: " + a[i] + " */"); continue; }
            seen.put(f, 0); queue.add(f);
        }
        while (!queue.isEmpty()) {
            Function f = queue.poll();
            int d = seen.get(f);
            DecompileResults r = di.decompileFunction(f, 60, monitor);
            code.put(f, r.decompileCompleted() ? r.getDecompiledFunction().getC() : "/* decompile failed */");
            if (d >= depth || r.getHighFunction() == null) continue;
            Iterator<PcodeOpAST> ops = r.getHighFunction().getPcodeOps();
            while (ops.hasNext()) {
                PcodeOpAST op = ops.next();
                if (op.getOpcode() != PcodeOp.CALL) continue;
                Address t = op.getInput(0).getAddress();
                Function c = fm.getFunctionAt(t);
                if (c == null) continue;
                if (c.isThunk() && c.getThunkedFunction(true) != null) c = c.getThunkedFunction(true);
                if (c.isExternal() || seen.containsKey(c)) continue;
                boolean skip = false;
                for (String s : SKIP) if (c.getName().contains(s)) skip = true;
                seen.put(c, skip ? Integer.MAX_VALUE : d + 1);
                if (!skip) queue.add(c);
            }
        }
        for (Map.Entry<Function, Integer> e : seen.entrySet()) {
            Function f = e.getKey();
            boolean skipped = e.getValue() == Integer.MAX_VALUE;
            out.printf("%n/* ===== %s @ %s (%s) ===== */%n", f.getName(), f.getEntryPoint(), skipped ? "runtime, not expanded" : "depth " + e.getValue());
            if (!skipped && code.containsKey(f)) out.println(code.get(f));
        }
        out.close();
    }
}
