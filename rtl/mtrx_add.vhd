library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.std_logic_misc.ALL;

-- Uncomment the following library declaration if using
-- arithmetic functions with Signed or Unsigned values
use IEEE.NUMERIC_STD.ALL;

-- Uncomment the following library declaration if instantiating
-- any Xilinx primitives in this code.
--library UNISIM;
--use UNISIM.VComponents.all;

--
--
--
entity mtrx_add is
Generic (
  MTRX_AW : positive := 5;  -- 2**MTRX_AW = max matrix index
  BRAM_DW : positive := 64;
  -- Data latency. Consist of:
  -- 1) address path to BRAM
  -- 2) BRAM data latency (generally 1 cycle)
  -- 3) data path from BRAM to device
  DAT_LAT : positive range 1 to 15 := 1
);
Port (
  -- control interface
  rst_i  : in  std_logic; -- active high. Must be used before every new calculation
  clk_i  : in  std_logic;
  m_size_i, p_size_i, n_size_i : in  std_logic_vector(MTRX_AW-1 downto 0);
  rdy_o  : out std_logic := '0'; -- active high 1 cycle
  err_o  : out std_logic := '0';
  sub_not_add_i : in std_logic;
  
  -- BRAM interface
  -- Note: there are no clocks for BRAMs. They are handle in higher level
  bram_adr_a_o : out std_logic_vector(2*MTRX_AW-1 downto 0);
  bram_adr_b_o : out std_logic_vector(2*MTRX_AW-1 downto 0);
  bram_adr_c_o : out std_logic_vector(2*MTRX_AW-1 downto 0);
  bram_dat_a_i : in  std_logic_vector(BRAM_DW-1 downto 0);
  bram_dat_b_i : in  std_logic_vector(BRAM_DW-1 downto 0);
  bram_dat_c_o : out std_logic_vector(BRAM_DW-1 downto 0);
  bram_ce_a_o  : out std_logic;
  bram_ce_b_o  : out std_logic;
  bram_ce_c_o  : out std_logic;
  bram_we_o    : out std_logic -- for C bram
);
end mtrx_add;


-----------------------------------------------------------------------------

architecture beh of mtrx_add is
  
  -- operand and result addresses registers
  signal AB_adr : std_logic_vector(2*MTRX_AW-1 downto 0):= (others => '0');
  signal AB_ce  : std_logic := '0';
  signal C_ce   : std_logic := '0';
  signal C_adr  : std_logic_vector(2*MTRX_AW-1 downto 0):= (others => '0');
  signal m_size, n_size : std_logic_vector(MTRX_AW-1 downto 0):= (others => '0');
  signal lat_i, lat_o : natural range 0 to 15 := DAT_LAT;

  signal end_c_iter  : std_logic := '0';
  signal rst_iter    : std_logic := '1';
  signal ce_ab_iter  : std_logic := '0';
  signal add_rdy : std_logic := '0';
  
  -- adder control signals
  signal add_nd : std_logic := '0';

  -- state machine
  type state_t is (IDLE, ADR_PRELOAD, DAT_PRELOAD, ACTIVE, FLUSH, HALT);
  signal state : state_t := IDLE;

begin
  
  --
  -- address iterator for IN matrices
  --
  iter_ab : entity work.mtrx_iter_seq
  generic map (
    MTRX_AW => MTRX_AW
  )
  port map (
    rst_i  => rst_iter,
    clk_i  => clk_i,
    m_i    => m_size,
    n_i    => n_size,
    ce_i   => ce_ab_iter,
    end_o  => open,
    dv_o   => AB_ce,
    adr_o  => AB_adr
  );

  --
  -- address iterator for OUT matrix
  --
  iter_c : entity work.mtrx_iter_seq
  generic map (
    MTRX_AW => MTRX_AW
  )
  port map (
    rst_i  => rst_iter,
    clk_i  => clk_i,
    m_i    => m_size,
    n_i    => n_size,
    ce_i   => add_rdy,
    end_o  => end_c_iter,
    dv_o   => C_ce,
    adr_o  => C_adr
  );
  
  --
  -- delay line connecting data_valid signal from input address
  -- iterator to operation_nd and ce of the adder
  --
  add_nd_delay : entity work.delay
  generic map (
    LAT => DAT_LAT,
    WIDTH => 1,
    default => '0'
  )
  port map (
    clk   => clk_i,
    ce    => '1',
    di(0) => AB_ce,
    do(0) => add_nd
  );
  
  --
  -- adder
  --
  dadd : entity work.dadd
  port map (
    a      => bram_dat_a_i,
    b      => bram_dat_b_i,
    result => bram_dat_c_o,
    clk    => clk_i,
    ce     => '1',
    rdy    => add_rdy,
    operation(5 downto 1) => "00000",
    operation(0) => sub_not_add_i,
    operation_nd => add_nd
  );
  
  bram_adr_a_o <= AB_adr;
  bram_adr_b_o <= AB_adr;
  bram_adr_c_o <= C_adr;
  bram_ce_a_o  <= AB_ce;
  bram_ce_b_o  <= AB_ce;
  bram_ce_c_o  <= C_ce;
  bram_we_o    <= add_rdy;
  
  --
  -- Main state machine
  -- 
  main : process(clk_i)
  begin
    if rising_edge(clk_i) then
      if (rst_i = '1') then
        state   <= IDLE;
        lat_i   <= DAT_LAT;
        lat_o   <= DAT_LAT / 2;
        rst_iter  <= '1';
        err_o <= '0';
        rdy_o <= '0';
      else
        err_o <= '0';
        rdy_o <= '0';
        case state is
        when IDLE =>
          if (p_size_i > 0) -- error
          then
            err_o <= '1';
            state <= HALT;
          else
            m_size  <= m_size_i;
            n_size  <= n_size_i;
            state   <= ADR_PRELOAD;
          end if;
          
        when ADR_PRELOAD =>
          rst_iter <= '0';
          ce_ab_iter  <= '1';
          lat_i <= lat_i - 1;
          state <= DAT_PRELOAD;
            
        when DAT_PRELOAD =>
          lat_i <= lat_i - 1;
          if (lat_i = 0) then
            state <= ACTIVE;
          end if;

        when ACTIVE =>
          if end_c_iter = '1' then
            rst_iter   <= '1';
            ce_ab_iter <= '0';
            state      <= FLUSH;
          end if;

        when FLUSH =>
          lat_o <= lat_o - 1;
          if (lat_o = 0) then
            state <= HALT;
            rdy_o <= '1';
          end if;

        when HALT =>
          state <= HALT;
        end case;
      end if; -- clk
    end if; -- rst
  end process;

end beh;


