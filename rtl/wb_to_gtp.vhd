library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
library UNISIM;
use UNISIM.VCOMPONENTS.all;
library gtp_lib;
library i2c_lib;

entity wb_to_gtp is

  port (
    REFCLK0_N_IN : in    std_logic;     -- GTP refclk
    REFCLK0_P_IN : in    std_logic;
    CSDA         : inout std_logic;     -- i2c to clock gen
    CSCL         : inout std_logic;

    RST_IN : in std_logic;              -- active high
    FCLK   : in std_logic;              -- fpga clock 24.84 MHz

    -- GTP frontend
    RXN_IN  : in  std_logic_vector(3 downto 0);
    RXP_IN  : in  std_logic_vector(3 downto 0);
    TXN_OUT : out std_logic_vector(3 downto 0);
    TXP_OUT : out std_logic_vector(3 downto 0);

    -- MCU signals
    UART6_TX        : in  std_logic;
    UART6_RX        : out std_logic;
    UART6_RTS       : in  std_logic;
    UART6_CTS       : out std_logic;
    MODTELEM_RX_MNU : out std_logic;

    -- Wishbone signals
    pwm_clk_i  : in  std_logic;
    pwm_sel_i  : in  std_logic;
    pwm_stb_i  : in  std_logic;
    pwm_we_i   : in  std_logic;
    pwm_err_o  : out std_logic;
    pwm_ack_o  : out std_logic;
    pwm_adr_i  : in  std_logic_vector(15 downto 0);
    pwm_dat_o  : out std_logic_vector(15 downto 0);
    pwm_dat_i  : in  std_logic_vector(15 downto 0);
    uart_clk_i : in  std_logic;
    uart_sel_i : in  std_logic;
    uart_stb_i : in  std_logic;
    uart_we_i  : in  std_logic;
    uart_err_o : out std_logic;
    uart_ack_o : out std_logic;
    uart_adr_i : in  std_logic_vector(15 downto 0);
    uart_dat_o : out std_logic_vector(15 downto 0);
    uart_dat_i : in  std_logic_vector(15 downto 0));

end entity wb_to_gtp;

architecture rtl of wb_to_gtp is

  signal clk : std_logic;               -- fpga clock 24.84
  signal rst : std_logic;

  -- GTP clocks
  signal refclk0_i    : std_logic;      -- reference clock from IDT chip
  signal txusrclk8_01 : std_logic;      -- TX parallel clock tile 0
  signal txusrclk8_23 : std_logic;      -- TX parallel clock tile 1
  signal rxusrclk8_0  : std_logic;      -- RX parallel clock gtp0
  signal rxusrclk8_1  : std_logic;      -- RX parallel clock gtp1
  signal rxusrclk8_2  : std_logic;      -- RX parallel clock gtp2
  signal rxusrclk8_3  : std_logic;      -- RX parallel clock gtp3

  signal gtpreset_in_i   : std_logic_vector (3 downto 0);
  signal plllkdet_out_i  : std_logic_vector (3 downto 0);  -- PLL lock
  signal resetdone_out_i : std_logic_vector (3 downto 0);

  -- GTP RX interface
  signal rxdata0_out_i         : std_logic_vector (7 downto 0);
  signal rxdata1_out_i         : std_logic_vector (7 downto 0);
  signal rxdata2_out_i         : std_logic_vector (7 downto 0);
  signal rxdata3_out_i         : std_logic_vector (7 downto 0);
  signal rxchariscomma_out_i   : std_logic_vector (3 downto 0);
  signal rxcharisk_out_i       : std_logic_vector (3 downto 0);
  signal rxbyteisaligned_out_i : std_logic_vector (3 downto 0);
  signal rxbyterealign_out_i   : std_logic_vector (3 downto 0);
  signal rxbufstatus_out_i     : std_logic_vector (11 downto 0);

  -- GTP TX interface
  signal txdata0_in_i      : std_logic_vector (7 downto 0);
  signal txdata1_in_i      : std_logic_vector (7 downto 0);
  signal txdata2_in_i      : std_logic_vector (7 downto 0);
  signal txdata3_in_i      : std_logic_vector (7 downto 0);
  signal txcharisk_in_i    : std_logic_vector (3 downto 0);
  signal txbufstatus_out_i : std_logic_vector (7 downto 0);

  -- Interconnect signals
  signal pwm_data_tx_i : std_logic_vector (15 downto 0);  -- to MSI
  signal pwm_en_tx_i   : std_logic;                       -- to MSI
  signal uart_tx_i     : std_logic_vector (15 downto 0);  -- to MSI
  signal uart_rts_i    : std_logic_vector (15 downto 0);  -- to MSI
  signal pwm_data_rx_i : std_logic_vector (15 downto 0);  -- from MSI
  signal pwm_en_rx_i   : std_logic;                       -- from MSI
  signal uart_rx_i     : std_logic_vector (15 downto 0);  -- from MSI
  signal uart_cts_i    : std_logic_vector (15 downto 0);  -- from MSI

begin

  rst             <= RST_IN;
  clk             <= FCLK;
  MODTELEM_RX_MNU <= UART6_TX;

  gtpreset_in_i <= (others => rst);

  -- Temporary values for unused signals (warning suppression)
  txdata1_in_i            <= X"00";
  txdata3_in_i            <= X"00";
  txcharisk_in_i(1)       <= '0';
  txcharisk_in_i(3)       <= '0';
  uart_tx_i(15 downto 2)  <= uart_rx_i(15 downto 2);
  uart_rts_i(15 downto 2) <= uart_cts_i(15 downto 2);

  refclk_ibufds_i : IBUFDS
    port map
    (
      O  => refclk0_i,
      I  => REFCLK0_P_IN,
      IB => REFCLK0_N_IN
      );

  -- Clock generator I2C programming
  i2c_clkgen_prog_1 : entity i2c_lib.i2c_clkgen_prog
    port map (
      CLK => clk,
      RST => rst,
      SDA => CSDA,
      SCL => CSCL
      );

  wb_pwm_1 : entity work.wb_pwm
    generic map (
      PWM_CHANNELS    => 16,
      PWM_TX_INTERVAL => 1024)          -- clk_gtp_tx cycles
    port map (
      rst          => rst,
      clk_gtp_tx   => txusrclk8_23,
      clk_gtp_rx   => rxusrclk8_2,
      PWM_DATA_IN  => pwm_data_rx_i,
      PWM_EN_IN    => pwm_en_rx_i,
      PWM_DATA_OUT => pwm_data_tx_i,
      PWM_EN_OUT   => pwm_en_tx_i,
      -- Wishbone signals
      clk_i        => pwm_clk_i,
      sel_i        => pwm_sel_i,
      stb_i        => pwm_stb_i,
      we_i         => pwm_we_i,
      err_o        => pwm_err_o,
      ack_o        => pwm_ack_o,
      adr_i        => pwm_adr_i,
      dat_o        => pwm_dat_o,
      dat_i        => pwm_dat_i);

  wb_uart_1 : entity work.wb_uart
    generic map (
      UART_CHANNELS => 2)
    port map (
      rst      => rst,
      UART_TX  => uart_tx_i(1 downto 0),
      UART_RTS => uart_rts_i(1 downto 0),
      UART_RX  => uart_rx_i(1 downto 0),
      UART_CTS => uart_cts_i(1 downto 0),
      -- Wishbone signals
      clk_i    => uart_clk_i,
      sel_i    => uart_sel_i,
      stb_i    => uart_stb_i,
      we_i     => uart_we_i,
      err_o    => uart_err_o,
      ack_o    => uart_ack_o,
      adr_i    => uart_adr_i,
      dat_o    => uart_dat_o,
      dat_i    => uart_dat_i);

  -- RX interface gtp0 (from MORS)
  post_rx_mnu_0 : entity work.post_rx_mnu(gtp0)
    port map (
      clk               => rxusrclk8_0,
      rst               => rst,
      GTP_RXDATA        => rxdata0_out_i,
      GTP_CHARISK       => rxcharisk_out_i(0),
      GTP_BYTEISALIGNED => rxbyteisaligned_out_i(0),
      USART1_RX         => UART6_RX,
      USART1_CTS        => UART6_CTS,
      PWM_DATA_OUT      => open,
      PWM_EN_OUT        => open,
      UART_RX           => open,
      UART_CTS          => open);

  -- RX interface gtp2 (from MSI)
  post_rx_mnu_2 : entity work.post_rx_mnu(gtp2)
    generic map (
      PWM_START_CHAR => X"1C",
      PWM_CHANNELS   => 19,             -- ch 17-19 for odometer
      UART_CHANNELS  => 16)
    port map (
      clk               => rxusrclk8_2,
      rst               => rst,
      GTP_RXDATA        => rxdata2_out_i,
      GTP_CHARISK       => rxcharisk_out_i(2),
      GTP_BYTEISALIGNED => rxbyteisaligned_out_i(2),
      USART1_RX         => open,
      USART1_CTS        => open,
      PWM_DATA_OUT      => pwm_data_rx_i,
      PWM_EN_OUT        => pwm_en_rx_i,
      UART_RX           => uart_rx_i,
      UART_CTS          => uart_cts_i);

  -- TX interface gtp0 (to MORS)
  pre_tx_mnu_0 : entity work.pre_tx_mnu(gtp0)
    generic map (
      COMMA_8B       => X"BC",          -- K28.5
      COMMA_INTERVAL => 256)
    port map (
      clk           => txusrclk8_01,
      rst           => rst,
      USART1_TX     => UART6_TX,
      USART1_RTS    => UART6_RTS,
      PWM_DATA_IN   => X"0000",
      PWM_EN_IN     => '0',
      UART_TX       => X"0000",
      UART_RTS      => X"0000",
      GTP_RESETDONE => resetdone_out_i(0),
      GTP_PLLLKDET  => plllkdet_out_i(0),
      GTP_TXDATA    => txdata0_in_i,
      GTP_CHARISK   => txcharisk_in_i(0));

  -- TX interface gtp2 (to MSI)
  pre_tx_mnu_2 : entity work.pre_tx_mnu(gtp2)
    generic map (
      COMMA_8B       => X"BC",          -- K28.5
      PWM_START_CHAR => X"1C",          -- K28.0
      UART_CHANNELS  => 16,
      PWM_CHANNELS   => 16)
    port map (
      clk           => txusrclk8_23,
      rst           => rst,
      USART1_TX     => '0',
      USART1_RTS    => '0',
      PWM_DATA_IN   => pwm_data_tx_i,
      PWM_EN_IN     => pwm_en_tx_i,
      UART_TX       => uart_tx_i,
      UART_RTS      => uart_rts_i,
      GTP_RESETDONE => resetdone_out_i(2),
      GTP_PLLLKDET  => plllkdet_out_i(2),
      GTP_TXDATA    => txdata2_in_i,
      GTP_CHARISK   => txcharisk_in_i(2));

  sp6_gtp_top_tile0 : entity gtp_lib.sp6_gtp_top
    port map (
      REFCLK0_IN          => refclk0_i,
      GTPRESET_IN         => gtpreset_in_i (1 downto 0),
      PLLLKDET_OUT        => plllkdet_out_i (1 downto 0),
      RESETDONE_OUT       => resetdone_out_i (1 downto 0),
      RXUSRCLK8_0_OUT     => rxusrclk8_0,
      RXUSRCLK8_1_OUT     => rxusrclk8_1,
      TXUSRCLK8_OUT       => txusrclk8_01,
      RXDATA0_OUT         => rxdata0_out_i,
      RXDATA1_OUT         => rxdata1_out_i,
      RXN_IN              => RXN_IN (1 downto 0),
      RXP_IN              => RXP_IN (1 downto 0),
      RXCHARISCOMMA_OUT   => rxchariscomma_out_i (1 downto 0),
      RXCHARISK_OUT       => rxcharisk_out_i (1 downto 0),
      RXBYTEISALIGNED_OUT => rxbyteisaligned_out_i (1 downto 0),
      RXBYTEREALIGN_OUT   => rxbyterealign_out_i (1 downto 0),
      RXBUFSTATUS_OUT     => rxbufstatus_out_i (5 downto 0),
      TXDATA0_IN          => txdata0_in_i,
      TXDATA1_IN          => txdata1_in_i,
      TXN_OUT             => TXN_OUT (1 downto 0),
      TXP_OUT             => TXP_OUT (1 downto 0),
      TXCHARISK_IN        => txcharisk_in_i (1 downto 0),
      TXBUFSTATUS_OUT     => txbufstatus_out_i (3 downto 0));

  sp6_gtp_top_tile1 : entity gtp_lib.sp6_gtp_top
    port map (
      REFCLK0_IN          => refclk0_i,
      GTPRESET_IN         => gtpreset_in_i (3 downto 2),
      PLLLKDET_OUT        => plllkdet_out_i (3 downto 2),
      RESETDONE_OUT       => resetdone_out_i (3 downto 2),
      RXUSRCLK8_0_OUT     => rxusrclk8_2,
      RXUSRCLK8_1_OUT     => rxusrclk8_3,
      TXUSRCLK8_OUT       => txusrclk8_23,
      RXDATA0_OUT         => rxdata2_out_i,
      RXDATA1_OUT         => rxdata3_out_i,
      RXN_IN              => RXN_IN (3 downto 2),
      RXP_IN              => RXP_IN (3 downto 2),
      RXCHARISCOMMA_OUT   => rxchariscomma_out_i (3 downto 2),
      RXCHARISK_OUT       => rxcharisk_out_i (3 downto 2),
      RXBYTEISALIGNED_OUT => rxbyteisaligned_out_i (3 downto 2),
      RXBYTEREALIGN_OUT   => rxbyterealign_out_i (3 downto 2),
      RXBUFSTATUS_OUT     => rxbufstatus_out_i (11 downto 6),
      TXDATA0_IN          => txdata2_in_i,
      TXDATA1_IN          => txdata3_in_i,
      TXN_OUT             => TXN_OUT (3 downto 2),
      TXP_OUT             => TXP_OUT (3 downto 2),
      TXCHARISK_IN        => txcharisk_in_i (3 downto 2),
      TXBUFSTATUS_OUT     => txbufstatus_out_i (7 downto 4));

end architecture rtl;
