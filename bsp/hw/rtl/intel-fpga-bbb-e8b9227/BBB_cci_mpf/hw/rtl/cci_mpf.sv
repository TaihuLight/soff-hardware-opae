//
// Copyright (c) 2016, Intel Corporation
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// Redistributions of source code must retain the above copyright notice, this
// list of conditions and the following disclaimer.
//
// Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
//
// Neither the name of the Intel Corporation nor the names of its contributors
// may be used to endorse or promote products derived from this software
// without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

//
// MPF main wrapper.  This module defines the edge of MPF that attaches
// to the FIU.  It then instantiates an MPF pipeline to implement the
// desired MPF services.
//

`include "cci_mpf_if.vh"
`include "cci_mpf_csrs.vh"
`include "cci_mpf_shim_edge.vh"
`include "cci_mpf_shim_pwrite.vh"


//
// This wrapper is a reference implementation of the composition of shims.
// Developers are free to compose memories with other properties.
//

module cci_mpf
  #(
    // Instance ID reported in feature IDs of all device feature
    // headers instantiated under this instance of MPF.  If only a single
    // MPF instance is instantiated in the AFU then leaving the instance
    // ID at 1 is probably the right choice.
    parameter MPF_INSTANCE_ID = 1,

    // MMIO base address (byte level) allocated to MPF for feature lists
    // and CSRs.  The AFU allocating this module must build at least
    // a device feature header (DFH) for the AFU.  The chain of device
    // features in the AFU must then point to the base address here
    // as another feature in the chain.  MPF will continue the list.
    // The base address here must point to a region that is at least
    // CCI_MPF_MMIO_SIZE bytes.
    parameter DFH_MMIO_BASE_ADDR = 0,

    // Address of the next device feature header outside MPF.  MPF will
    // terminate the feature list if the next address is 0.
    parameter DFH_MMIO_NEXT_ADDR = 0,

    // Enable virtual to physical translation?
    parameter ENABLE_VTP = 1,
    // Two implementations of physical to virtual page translation are
    // available in VTP. Pick mode "HARDWARE_WALKER" to walk the VTP
    // page table using AFU-generated memory reads. Pick mode
    // "SOFTWARE_SERVICE" to send translation requests to software.
    // In HARDWARE_WALKER mode it is the user code's responsibility to
    // pin all pages that may be touched by the FPGA. The SOFTWARE_SERVICE
    // mode may pin pages automatically on demand.
    parameter string VTP_PT_MODE = "HARDWARE_WALKER",
    // In its default mode, VTP blocks a channel's request traffic following
    // a translation failure. Some AFUs may need to handle translation
    // failure on their own. When VTP_HALT_ON_FAILURE is 0, failed address
    // translations emerge from MPF with the hdr.ext.addrIsVirtual bit still
    // set. For successful translations, the addrIsVirtual bit is cleared to
    // indicate that the address is now physical.
    parameter VTP_HALT_ON_FAILURE = 1,

    // Enable mapping of eVC_VA to physical channels?  AFUs that both use
    // eVC_VA and read back memory locations written by the AFU must either
    // emit WrFence on VA or use explicit physical channels and enforce
    // write/read order.  Each method has tradeoffs.  WrFence VA is expensive
    // and should be emitted only infrequently.  Memory requests to eVC_VA
    // may have higher bandwidth than explicit mapping.  The MPF module for
    // physical channel mapping is optimized for each CCI platform.
    //
    // The mapVAtoPhysChannel extended header bit must be set on each
    // request to enable mapping.
    parameter ENABLE_VC_MAP = 0,
    // When ENABLE_VC_MAP is set the mapping is either static for the entire
    // run or dynamic, changing in response to traffic patterns.  The mapper
    // guarantees synchronization when the mapping changes by emitting a
    // WrFence on eVC_VA and draining all reads.  Ignored when ENABLE_VC_MAP
    // is 0.
    parameter ENABLE_DYNAMIC_VC_MAPPING = 1,

    // Manage traffic to reduce latency without sacrificing bandwidth?
    // The blue bitstream buffers for a given channel may be larger than
    // necessary to sustain full bandwidth.  Allowing more requests beyond
    // this threshold to enter the channel increases latency without
    // increasing bandwidth.  While this is fine for some applications,
    // those with multiple kernels connected to the CCI memory interface
    // may see performance gains when a kernel's performance is a
    // latency-sensitive.
    parameter ENABLE_LATENCY_QOS = 0,

    // Enforce write/write and write/read ordering with cache lines?
    parameter ENFORCE_WR_ORDER = 0,

    // Return read responses in the order they were requested?
    parameter SORT_READ_RESPONSES = 1,

    // Preserve Mdata field in write requests?  Turn this off if the AFU
    // merely counts write responses instead of checking Mdata.
    parameter PRESERVE_WRITE_MDATA = 0,

    // Enable partial write emulation.  The original CCI-P standard
    // had no support for partial writes.  MPF can emulate partial
    // writes using read-modify-write.  The original MPF encoding
    // was a byte-level mask, one bit per byte.  CCI-P has since
    // added an encoding for partial writes, but the encoding supports
    // only a contiguous range of bytes -- a limitation imposed by
    // PCIe.  MPF supports either encoding, depending on the setting
    // of PARTIAL_WRITE_MODE below.
    //
    // NOTE: When PARTIAL_WRITE_MODE is set to BYTE_RANGE and the
    // platform supports CCI-P with byte ranges, partial write emulation
    // in MPF is automatically disabled even when ENABLE_PARTIAL_WRITES
    // is set.  This behavior allows an AFU to set ENABLE_PARTIAL_WRITES
    // and MPF will automatically either emulate the behavior or pass
    // the request to the FIU, as appropriate.
    //
    // In emulation mode, when coupled with ENFORCE_WR_ORDER, partial
    // writes are free of races on the FPGA side.  Due to the read-modify-
    // write in the emulation, there are no guarantees of atomicity and
    // there is no protection against races with CPU-generates writes.
    parameter ENABLE_PARTIAL_WRITES = 0,
    // CCI-P added partial write encoding.  Use "BYTE_MASK" for the
    // original MPF mask -- one bit per byte.  Use "BYTE_RANGE" for the
    // CCI-P native encoding using byte_start/byte_len.
    parameter string PARTIAL_WRITE_MODE = "BYTE_MASK",

    // Experimental:  Merge nearby reads from the same address?  Some
    // applications generate reads to the same line within a few cycles
    // of each other.  This module reduces the requests to single host
    // read and replicates the result.  The module requires a wide
    // block RAM FIFO, so should not be enabled without some thought.
    parameter MERGE_DUPLICATE_READS = 0
    )
   (
    input  logic      clk,

    //
    // Signals connecting to QA Platform
    //
    cci_mpf_if.to_fiu fiu,

    //
    // Signals connecting to AFU, the client code
    //
    cci_mpf_if.to_afu afu,

    //
    // Is a request active somewhere in the memory?  Clients waiting for
    // all responses to complete can monitor these signals.
    //
    output logic c0NotEmpty,
    output logic c1NotEmpty
    );

    // Maximum number of outstanding read and write requests per channel
`ifdef PLATFORM_IF_AVAIL
    // Use the platform database.  VA will have the largest buffer requirements.
    // The value in the database doesn't include the latency effects of reorder
    // buffers and the other MPF shims.  Add 50%.
    localparam MAX_ACTIVE_REQS_RAW = (ccip_cfg_pkg::C0_MAX_BW_ACTIVE_LINES[0] +
                                      (ccip_cfg_pkg::C0_MAX_BW_ACTIVE_LINES[0] >> 1));
    // Round up to a power of 2.
    localparam MAX_ACTIVE_REQS = (2 ** $clog2(MAX_ACTIVE_REQS_RAW));
`elsif MPF_PLATFORM_DCP_PCIE
    localparam MAX_ACTIVE_REQS = 512;
`else
    localparam MAX_ACTIVE_REQS = 1024;
`endif

    // Is a native CCI-P encoding available for writing a byte range?
`ifdef CCIP_ENCODING_HAS_BYTE_WR
    // Yes. If MPF is configured to use byte ranges (not the original MPF
    // bit-mask encoding) and the platform supports it then there is no
    // need for partial write emulation.
    localparam MPF_ENABLE_PWRITE_EMUL = ENABLE_PARTIAL_WRITES &&
                                        ((PARTIAL_WRITE_MODE != "BYTE_RANGE") ||
                                         ! ccip_cfg_pkg::BYTE_EN_SUPPORTED);
`else
    // There is no native encoding of byte ranges available. Only emulation
    // is an option.
    localparam MPF_ENABLE_PWRITE_EMUL = ENABLE_PARTIAL_WRITES;
`endif

    // Reserved bits in the mdata field, used by various modules.
    localparam RESERVED_MDATA_IDX = CCI_PLATFORM_MDATA_WIDTH - 2;

    // No point in enabling VC Map when there is only one channel
    localparam MPF_ENABLE_VC_MAP =
        (MPF_PLATFORM_NUM_PHYSICAL_CHANNELS > 1) ? ENABLE_VC_MAP : 0;

    logic reset = 1'b1;
    always @(posedge clk)
    begin
        reset <= fiu.reset;
    end

    cci_mpf_csrs mpf_csrs ();


    // ====================================================================
    //
    //  Track channel credits, limiting the number of outstanding requests.
    //  Thresholds are platform-specific.
    //
    //  This module must go right at the edge of the FIU since it is
    //  managing the almost full signal up the stack to maintain optimal
    //  traffic into the FIU.
    //
    // ====================================================================

    cci_mpf_if stgm1_fiu_latency_qos (.clk);

    generate
        if (ENABLE_LATENCY_QOS)
        begin : lat_qos
            cci_mpf_shim_latency_qos
              #(
                .MAX_ACTIVE_LINES(MAX_ACTIVE_REQS)
                )
              latency_qos
               (
                .clk,
                .fiu(fiu),
                .afu(stgm1_fiu_latency_qos),
                .csrs(mpf_csrs)
                );
        end
        else
        begin : no_lat_qos
            cci_mpf_shim_null
              no_latency_qos
               (
                .clk,
                .fiu(fiu),
                .afu(stgm1_fiu_latency_qos)
                );
        end
    endgenerate


    // ====================================================================
    //
    //  Mandatory MPF edge connection to both the external AFU and FIU
    //  links and to both ends of the MPF pipeline defined in this module.
    //
    // ====================================================================

    cci_mpf_if stgm2_mpf_fiu (.clk);

    // Number of unique write request packets that may be active in MPF.
    // Multi-flit packets count as one entry. Packets become active when
    // a TX request arrives from the AFU and are inactivated as the TX
    // request exits MPF toward the FIU.
    localparam N_WRITE_HEAP_ENTRIES = 128;

    cci_mpf_shim_edge_if
      #(
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES)
        )
      edge_if();

    cci_mpf_shim_pwrite_if
      #(
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES)
        )
      pwrite();

    cci_mpf_shim_pwrite_lock_if
      #(
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES)
        )
      pwrite_lock();

    mpf_vtp_pt_host_if pt_fim();

    cci_mpf_shim_edge_fiu
      #(
        .ENABLE_PARTIAL_WRITES(MPF_ENABLE_PWRITE_EMUL),
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES),

        // VTP needs to generate loads internally in order to walk the
        // page table.  The reserved bit in Mdata is a location offered
        // to the page table walker to tag internal loads.  The Mdata
        // location is guaranteed to be zero on all requests flowing
        // in to VTP from the AFU.
        .RESERVED_MDATA_IDX(RESERVED_MDATA_IDX)
        )
      mpf_edge_fiu
       (
        .clk,
        .fiu(stgm1_fiu_latency_qos),
        .afu(stgm2_mpf_fiu),
        .afu_edge(edge_if),
        .pt_fim,
        .pwrite,
        .pwrite_lock
        );


    // ====================================================================
    //
    //  Manage CSRs used by MPF
    //
    // ====================================================================

    cci_mpf_if stgm3_fiu_csrs (.clk);

    // The VTP service manages its own CSR space. Connect the generic
    // register read/write interface exported by VTP to the MPF MMIO CSR
    // manager, which will forward MMIO events to the VTP service.
    mpf_services_gen_csr_if
      #(
        .N_ENTRIES(mpf_vtp_pkg::MPF_VTP_CSR_N_ENTRIES),
        .N_DATA_BITS(mpf_vtp_pkg::MPF_VTP_CSR_N_DATA_BITS)
        )
      vtp_gen_csrs();

    cci_mpf_shim_csr
      #(
        .MPF_INSTANCE_ID(MPF_INSTANCE_ID),
        .DFH_MMIO_BASE_ADDR(DFH_MMIO_BASE_ADDR),
        .DFH_MMIO_NEXT_ADDR(DFH_MMIO_NEXT_ADDR),
        .MPF_ENABLE_VTP(ENABLE_VTP),
        .MPF_ENABLE_RSP_ORDER(SORT_READ_RESPONSES),
        .MPF_ENABLE_VC_MAP(MPF_ENABLE_VC_MAP),
        .MPF_ENABLE_LATENCY_QOS(ENABLE_LATENCY_QOS),
        .MPF_ENABLE_WRO(ENFORCE_WR_ORDER),
        .MPF_ENABLE_PWRITE(MPF_ENABLE_PWRITE_EMUL)
        )
      csr
       (
        .clk,
        .fiu(stgm2_mpf_fiu),
        .afu(stgm3_fiu_csrs),
        .csrs(mpf_csrs),
        .events(mpf_csrs),
        .vtp_csrs(vtp_gen_csrs)
        );


    // ====================================================================
    //
    //  If VTP is enabled then add a translation server.  All VTP AFU
    //  pipeline shims will sends requests to this shared server.
    //
    // ====================================================================

    localparam N_VTP_PORTS = 2;

    mpf_vtp_port_if vtp_ports[N_VTP_PORTS] ();

    mpf_svc_vtp
      #(
        .ENABLE_VTP(ENABLE_VTP),
        .N_VTP_PORTS(N_VTP_PORTS),
        .VTP_PT_MODE(VTP_PT_MODE),
        .DEBUG_MESSAGES(0)
        )
      vtp
       (
        .clk,
        .reset,
        .vtp_ports,
        .pt_fim,
        .gen_csr_if(vtp_gen_csrs)
        );


    // ====================================================================
    //
    //  Instantiate an MPF pipeline composed of the desired shims
    //
    // ====================================================================

    cci_mpf_pipe_std
      #(
        .MAX_ACTIVE_REQS(MAX_ACTIVE_REQS),
        .MPF_INSTANCE_ID(MPF_INSTANCE_ID),
        .DFH_MMIO_BASE_ADDR(DFH_MMIO_BASE_ADDR),
        .DFH_MMIO_NEXT_ADDR(DFH_MMIO_NEXT_ADDR),
        .ENABLE_VTP(ENABLE_VTP),
        .VTP_HALT_ON_FAILURE(VTP_HALT_ON_FAILURE),
        .ENABLE_VC_MAP(MPF_ENABLE_VC_MAP),
        .ENABLE_DYNAMIC_VC_MAPPING(ENABLE_DYNAMIC_VC_MAPPING),
        .ENFORCE_WR_ORDER(ENFORCE_WR_ORDER),
        .SORT_READ_RESPONSES(SORT_READ_RESPONSES),
        .PRESERVE_WRITE_MDATA(PRESERVE_WRITE_MDATA),
        .MERGE_DUPLICATE_READS(MERGE_DUPLICATE_READS),
        .ENABLE_PARTIAL_WRITES(MPF_ENABLE_PWRITE_EMUL),
        .PARTIAL_WRITE_MODE(PARTIAL_WRITE_MODE),
        .N_WRITE_HEAP_ENTRIES(N_WRITE_HEAP_ENTRIES),
        .RESERVED_MDATA_IDX(RESERVED_MDATA_IDX)
        )
      mpf_pipe
       (
        .clk,
        .fiu(stgm3_fiu_csrs),
        .afu,
        .mpf_csrs,
        .edge_if,
        .pwrite,
        .pwrite_afu(pwrite),
        .pwrite_lock,
        .vtp_ports
        );


    // ====================================================================
    //
    //  Track active request counts
    //
    // ====================================================================

    // Leave an extra bit since the counter is at the edge before the
    // initial buffer that limits request counts to MAX_ACTIVE_REQS.
    // The count can thus be higher than MAX_ACTIVE_REQS here.
    typedef logic [$clog2(MAX_ACTIVE_REQS) : 0] t_active_cnt;

    t_active_cnt c0_num_active, c1_num_active;

    logic c0_active_incr, c0_active_decr;
    logic c1_active_incr, c1_active_decr;

    always_comb
    begin
        c0_active_incr = cci_mpf_c0TxIsReadReq(afu.c0Tx);
        c0_active_decr = cci_mpf_c0Rx_isEOP(afu.c0Rx);

        c1_active_incr = cci_mpf_c1TxIsWriteReq(afu.c1Tx) && afu.c1Tx.hdr.base.sop;
        c1_active_decr = cci_c1Rx_isWriteRsp(afu.c1Rx);
    end

    always_ff @(posedge clk)
    begin
        c0NotEmpty <= c0_active_incr || (|(c0_num_active));
        c1NotEmpty <= c1_active_incr || (|(c1_num_active));

        if (c0_active_incr != c0_active_decr)
        begin
            if (c0_active_incr)
                c0_num_active <= c0_num_active + t_active_cnt'(1);
            else
                c0_num_active <= c0_num_active - t_active_cnt'(1);
        end

        if (c1_active_incr != c1_active_decr)
        begin
            if (c1_active_incr)
                c1_num_active <= c1_num_active + t_active_cnt'(1);
            else
                c1_num_active <= c1_num_active - t_active_cnt'(1);
        end

        if (reset)
        begin
            c0NotEmpty <= 1'b0;
            c1NotEmpty <= 1'b0;

            c0_num_active <= t_active_cnt'(0);
            c1_num_active <= t_active_cnt'(0);
        end
    end

endmodule // cci_mpf
