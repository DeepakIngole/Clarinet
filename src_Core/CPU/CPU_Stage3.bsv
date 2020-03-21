// Copyright (c) 2016-2019 Bluespec, Inc. All Rights Reserved

package CPU_Stage3;

// ================================================================
// This is Stage 3 of the CPU.
// It is the WB ("Write Back") stage:
// - Writes back a GPR register value (if the instr has an Rd)
// - Updates CSR INSTRET
//     Note: this instr cannot be a CSRRx updating INSTRET, since
//           CSRRx is done completely in Stage1.


// Note: $displays are indented by (stage num x 4) spaces.
// for traditional pipeline display
//     IF
//         DM
//             WB
// i.e., 12 spaces for this stage.

// ================================================================
// Exports

export
CPU_Stage3_IFC (..),
mkCPU_Stage3;

// ================================================================
// BSV library imports

import ConfigReg    :: *;
import FIFOF        :: *;
import GetPut       :: *;
import ClientServer :: *;

// ----------------
// BSV additional libs

import Cur_Cycle :: *;

// ================================================================
// Project imports

import ISA_Decls   :: *;
import GPR_RegFile :: *;
`ifdef ISA_F
import FPR_RegFile :: *;
`endif
import CSR_RegFile :: *;
import CPU_Globals :: *;

// ================================================================
// Interface

interface CPU_Stage3_IFC;
   // ---- Reset
   interface Server #(Token, Token) server_reset;

   // ---- Output
   (* always_ready *)
   method Output_Stage3  out;

   (* always_ready *)
   method Action deq;

   // ---- Input
   (* always_ready *)
   method Action enq (Data_Stage2_to_Stage3 x);

   (* always_ready *)
   method Action set_full (Bool full);

   // ---- Debugging
   method Action show_state;
endinterface

// ================================================================
// Module

module mkCPU_Stage3 #(Bit #(4)         verbosity,
		      GPR_RegFile_IFC  gpr_regfile,
`ifdef ISA_F
		      FPR_RegFile_IFC  fpr_regfile,
`ifdef POSIT
                      PRF_RegFile_IFC  prf_regfile,
`endif
`endif
		      CSR_RegFile_IFC  csr_regfile)
                    (CPU_Stage3_IFC);

   FIFOF #(Token) f_reset_reqs <- mkFIFOF;
   FIFOF #(Token) f_reset_rsps <- mkFIFOF;

   Reg #(Bool)                  rg_full   <- mkReg (False);
   Reg #(Data_Stage2_to_Stage3) rg_stage3 <- mkRegU;    // From Stage 2

   // ----------------------------------------------------------------
   // BEHAVIOR

   let bypass_base = Bypass {bypass_state: BYPASS_RD_NONE,
			     rd:           rg_stage3.rd,
			     // WordXL        WordXL
			     rd_val:       rg_stage3.rd_val
			     };

`ifdef ISA_F
   let fbypass_base = FBypass {bypass_state: BYPASS_RD_NONE,
			       rd:           rg_stage3.rd,
			       // WordFL        WordFL
			       rd_val:       rg_stage3.frd_val
			       };
`endif

`ifdef POSIT
   let pbypass_base = PBypass {bypass_state: BYPASS_RD_NONE,
			       rd:           rg_stage3.rd,
			       // WordPL        WordPL
			       rd_val:       rg_stage3.prd_val
			       };
`endif

   rule rl_reset;
      f_reset_reqs.deq;
      rg_full <= False;
      f_reset_rsps.enq (?);
   endrule

   // ----------------
   // Combinational output function

   function Output_Stage3 fv_out;
      let bypass = bypass_base;
`ifdef ISA_F
      let fbypass = fbypass_base;
`ifdef POSIT
      let pbypass = pbypass_base;
`endif
      if (rg_stage3.rd_in_fpr) begin
         bypass.bypass_state = BYPASS_RD_NONE;
         pbypass.bypass_state = BYPASS_RD_NONE;
         fbypass.bypass_state = (rg_full && rg_stage3.rd_valid) ? BYPASS_RD_RDVAL
                                                                : BYPASS_RD_NONE;
      end

`ifdef POSIT
      else if ((rg_stage3.rd_in_prf) || (rg_stage3.no_rd_upd)) begin
         // It is important to make sure that the GPR bypass does
         // NOT get set by default for a quire operation
         bypass.bypass_state = BYPASS_RD_NONE;
         fbypass.bypass_state = BYPASS_RD_NONE;

         if ((rg_stage3.rd_in_prf) && (!rg_stage3.no_rd_upd)) 
            pbypass.bypass_state = (rg_full && rg_stage3.rd_valid) ? BYPASS_RD_RDVAL
                                                                   : BYPASS_RD_NONE;
      end
`endif

      else begin
         fbypass.bypass_state = BYPASS_RD_NONE;
         pbypass.bypass_state = BYPASS_RD_NONE;
         bypass.bypass_state = (rg_full && rg_stage3.rd_valid) ? BYPASS_RD_RDVAL
                                                               : BYPASS_RD_NONE;
      end
`else
      bypass.bypass_state = (rg_full && rg_stage3.rd_valid) ? BYPASS_RD_RDVAL
                                                            : BYPASS_RD_NONE;
`endif

      return Output_Stage3 {ostatus: (rg_full ? OSTATUS_PIPE : OSTATUS_EMPTY),
			    bypass : bypass
`ifdef ISA_F
			    , fbypass: fbypass
`ifdef ISA_F
			    , pbypass: pbypass
`endif
`endif
			    };
   endfunction

   // ----------------
   // Actions on 'deq': writeback Rd and update CSR INSTRET

   function Action fa_deq;
      action
	 // Writeback Rd if valid
	 if (rg_stage3.rd_valid) begin
`ifdef ISA_F
            // Write to FPR
            if (rg_stage3.rd_in_fpr)
               fpr_regfile.write_rd (rg_stage3.rd, rg_stage3.frd_val);

`ifdef POSIT
            else if ((rg_stage3.rd_in_prf) || (rg_stage3.no_rd_upd))
               // Important that GPR write is not triggered by
               // default for quire operations
               if ((rg_stage3.rd_in_prf) && (!rg_stage3.no_rd_upd))
                  prf_regfile.write_rd (rg_stage3.rd, rg_stage3.prd_val);
`endif
            else
               // Write to GPR
               gpr_regfile.write_rd (rg_stage3.rd, rg_stage3.rd_val);
`else
            // Write to GPR in a non-FD system
            gpr_regfile.write_rd (rg_stage3.rd, rg_stage3.rd_val);
`endif

	    if (verbosity > 1)
`ifdef ISA_F
               if (rg_stage3.rd_in_fpr)
                  $display ("    S3.fa_deq: write FRd 0x%0h, rd_val 0x%0h",
                            rg_stage3.rd, rg_stage3.frd_val);
`ifdef POSIT
               else if ((rg_stage3.rd_in_prf) || (rg_stage3.no_rd_upd))
                  if ((rg_stage3.rd_in_prf) && (!rg_stage3.no_rd_upd))
                     $display ("    S3.fa_deq: write PRd 0x%0h, rd_val 0x%0h",
                               rg_stage3.rd, rg_stage3.prd_val);
`endif
               else
`endif
               $display ("    S3.fa_deq: write GRd 0x%0h, rd_val 0x%0h",
                         rg_stage3.rd, rg_stage3.rd_val);

`ifdef ISA_F
            // Update FCSR.fflags
            if (rg_stage3.upd_flags)
               csr_regfile.ma_update_fcsr_fflags (rg_stage3.fpr_flags);

            // Update MSTATUS.FS
            if (rg_stage3.upd_flags || rg_stage3.rd_in_fpr)
               csr_regfile.ma_update_mstatus_fs (fs_xs_dirty);
`endif
	 end
      endaction
   endfunction

   // ----------------------------------------------------------------
   // INTERFACE

   // ---- Reset
   interface server_reset = toGPServer (f_reset_reqs, f_reset_rsps);

   // ---- Output

   method Output_Stage3  out;
      return fv_out;
   endmethod

   method Action deq;
      fa_deq;
   endmethod

   // ---- Input
   method Action enq (Data_Stage2_to_Stage3 x);
      rg_stage3 <= x;

      if (verbosity > 1)
	 $display ("    S3.enq: ", fshow (x));
   endmethod

   method Action set_full (Bool full);
      rg_full <= full;
   endmethod

   // ---- Debugging
   method Action show_state;
      if (rg_full)
	 $display ("    CPU_Stage3 state: ", fshow (rg_stage3));
      else
	 $display ("    CPU_Stage3 state: empty");
   endmethod
endmodule

// ================================================================

endpackage
