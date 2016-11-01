#include <xs1.h>
#include <xclib.h>
#include <print.h>
#include <platform.h>
#include <stdlib.h>
#include "otp_board_info.h"
#include "ethernet.h"
#include "ethernet_board_support.h"
#include <xscope.h>
#include "gptp.h"
#include "ethernet_conf.h"
#include "mac_custom_filter.h"
#include "debug_print.h"
//#include "c37.118.h"
//#include "udp.h"
#include <inttypes.h>
#include <stdlib.h>
#include <string.h>


#include <xs1.h>
#include <platform.h>
#include "otp_board_info.h"
#include "ethernet.h"
#include "smi.h"


#define UDP_HEADER_BYTES    8
#define IP_HEADER_BYTES     20
#define ETH_HEADER_BYTES    14

#define UDP_DEFAULT_PORT    4713

#define IP_DEFAULT_TTL      100
#define IP_VERSION          0x4
#define IP_IHL              0x5
#define IP_PROTOCOL_UDP     0x11

//extern uint8_t IP_SOURCE[4];
//extern uint8_t IP_DEST[4];
//
//extern uint8_t ETH_SOURCE[6];
//extern uint8_t ETH_DEST[6];

typedef struct eth_header {
    uint8_t dest[6];
    uint8_t source[6];
    uint16_t ethertype;
} ETH;

typedef struct ip_header {
    uint16_t info;
    uint16_t length;
    uint16_t id;
    uint16_t flags_frag;
    uint8_t ttl;
    uint8_t protocol;
    uint16_t checksum;
    uint32_t source;
    uint32_t dest;
    ETH eth;
} IP;

typedef struct udp_header {
    uint16_t source;
    uint16_t dest;
    uint16_t length;
    uint16_t checksum;
    IP ip;
} UDP;




uint8_t IP_SOURCE[4] = { 192, 168, 2, 126 };    // TODO: get local IP address at runtime
uint8_t IP_DEST[4] = { 192, 168, 2, 255 };

//uint8_T ETH_SOURCE[6] = { 0x00, 0x26, 0x9e, 0x53, 0x4b, 0x09 };   // TODO: get local MAC address at runtime
uint8_t ETH_SOURCE[6] = { 0x00, 0x01, 0x05, 0x21, 0x95, 0xCE }; // TODO: get local MAC address at runtime
uint8_t ETH_DEST[6] = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };

// a simple memcpy implementation, that reverses endian-ness
void reversememcpy(unsigned char *dst, const unsigned char *src, unsigned int len) {
//    while (len--) {
//        *dst++ = src[len];
//    }
    size_t i;
    for (i = 0; i < len; ++i) {
        dst[len - 1 - i] = src[i];
    }
}

// copies bytes to network format (big-endian)
void netmemcpy(unsigned char *dst, const unsigned char *src, unsigned int len) {
//#ifdef LITTLE_ENDIAN
    reversememcpy((unsigned char *)dst, (const unsigned char *)src, len);
//#else
//  memcpy((unsigned char *)dst, (const unsigned char *)src, len);
//#endif
}

int encodeETH(unsigned char* data, ETH* eth, const char *payload, int payload_length) {
    int size = 0;

    netmemcpy(&data[size], (const void*)eth->dest, 6);
    size += sizeof eth->dest;
    netmemcpy(&data[size], (const void*)eth->source, 6);
    size += sizeof eth->dest;
    netmemcpy(&data[size], (const void*)&eth->ethertype, sizeof eth->ethertype);
    size += sizeof eth->ethertype;

    return size;
}

uint16_t getIPChecksum(IP *ip) {
    uint32_t sum = ip->info + ip->length + ip->id + ip->flags_frag + ((ip->ttl << 8) | (ip->protocol)) + (ip->source & 0x0000FFFF) + ((ip->source & 0xFFFF0000) >> 16) + (ip->dest & 0x0000FFFF) + ((ip->dest & 0xFFFF0000) >> 16);
    uint8_t carry = (sum & 0x000F0000) >> 16;

    sum = sum + carry;

    return ~sum;
}

int encodeIP(unsigned char* data, IP* ip, const char *payload, int payload_length) {
    int size = 0;

    size += encodeETH(&data[size], &ip->eth, payload, payload_length);

    ip->length = IP_HEADER_BYTES + UDP_HEADER_BYTES + payload_length;
    ip->checksum = getIPChecksum(ip);

    netmemcpy(&data[size], (const void*)&ip->info, sizeof ip->info);
    size += sizeof ip->info;
    netmemcpy(&data[size], (const void*)&ip->length, sizeof ip->length);
    size += sizeof ip->length;
    netmemcpy(&data[size], (const void*)&ip->id, sizeof ip->id);
    size += sizeof ip->id;
    netmemcpy(&data[size], (const void*)&ip->flags_frag, sizeof ip->flags_frag);
    size += sizeof ip->flags_frag;
    netmemcpy(&data[size], (const void*)&ip->ttl, sizeof ip->ttl);
    size += sizeof ip->ttl;
    netmemcpy(&data[size], (const void*)&ip->protocol, sizeof ip->protocol);
    size += sizeof ip->protocol;
    netmemcpy(&data[size], (const void*)&ip->checksum, sizeof ip->checksum);
    size += sizeof ip->checksum;
    netmemcpy(&data[size], (const void*)&ip->source, sizeof ip->source);
    size += sizeof ip->source;
    netmemcpy(&data[size], (const void*)&ip->dest, sizeof ip->dest);
    size += sizeof ip->dest;

    return size;
}

int encode_UDP(unsigned char* data, UDP* udp, const char *payload, int payload_length) {
    int size = 0;

    size += encodeIP(&data[size], &udp->ip, payload, payload_length);

    udp->length = UDP_HEADER_BYTES + payload_length;
    udp->checksum = 0;

    netmemcpy(&data[size], (const void*)&udp->source, sizeof udp->source);
    size += sizeof udp->source;
    netmemcpy(&data[size], (const void*)&udp->dest, sizeof udp->dest);
    size += sizeof udp->dest;
    netmemcpy(&data[size], (const void*)&udp->length, sizeof udp->length);
    size += sizeof udp->length;
    netmemcpy(&data[size], (const void*)&udp->checksum, sizeof udp->checksum);
    size += sizeof udp->checksum;

    memcpy(&data[size], (const void*)payload, payload_length);
    size += payload_length;

    return size;
}


void init_existing_UDP(UDP *udp, uint8_t *ip, uint8_t *mac) {
    udp->source = UDP_DEFAULT_PORT;
    udp->dest = UDP_DEFAULT_PORT;

    udp->ip.info = ((IP_VERSION << 12) | (IP_IHL << 8)) & 0xFFFF;
    udp->ip.id = 0;
    udp->ip.flags_frag = 0;
    udp->ip.ttl = IP_DEFAULT_TTL;
    udp->ip.protocol = IP_PROTOCOL_UDP;

    if (ip == NULL) {
        netmemcpy((void *)&(udp->ip.source), IP_SOURCE, 4);
    }
    else {
        memcpy((void *)&(udp->ip.source), ip, 4);
    }
    netmemcpy((void *)&(udp->ip.dest), IP_DEST, 4);

    if (mac == NULL) {
        memcpy((void *)(udp->ip.eth.source), ETH_SOURCE, 6);
    }
    else {
        netmemcpy((void *)(udp->ip.eth.source), mac, 6);
    }
    memcpy((void *)(udp->ip.eth.dest), ETH_DEST, 6);
    udp->ip.eth.ethertype = 0x0800;
}

void set_UDP_dest(UDP *udp, uint8_t *ip, uint8_t *mac, uint16_t remote_port) {
    netmemcpy((void *)&(udp->ip.dest), ip, 4);
    memcpy((void *)(udp->ip.eth.dest), mac, 6);
    udp->dest = remote_port;
}











#define MIN(a,b) ((a) < (b) ? (a) : (b))

enum Message_Type { C37_118_Data, C37_118_CFG_1, C37_118_CFG_2, C37_118_CFG_3, C37_118_DATA_TRANSMISSION };

enum Command_Type { C37_118_DATA_OFF = 1, C37_118_DATA_ON = 2 };


UDP udp;
unsigned char buf[512];
uint16_t remote_port = 0;
uint8_t ip[] = { 192, 168, 2, 19 };// 124 };
uint8_t mac_add[] = { 0x83, 0x1c, 0x0e, 0x9b, 0x24, 0x00 };

uint8_t buf_payload[512];
//uint8_t buf_out[512];
//UDP udp;

//     Compute CRC-CCITT. *buf is a pointer to the first character in the message;
//    len is the number of characters in the message (not counting the CRC on the end)
uint16_t ComputeCRC(unsigned char *buf, unsigned char len) {
    uint16_t crc = 0xFFFF;
    uint16_t temp;
    uint16_t quick;
    int i;

    for (i = 0; i < len; i++) {
        temp = (crc >> 8) ^ buf[i];
        crc <<= 8;
        quick = temp ^ (temp >> 4);
        crc ^= quick;
        quick <<= 5;
        crc ^= quick;
        quick <<= 7;
        crc ^= quick;
    }

    return crc;
}

uint16_t write_data_transmission_frame(unsigned char *buf, uint32_t SOC_recv, uint16_t transmission_state) {
    uint16_t len = 0;
    unsigned char *FRAMESIZE_ptr;
    uint16_t FRAMESIZE = 0;

    uint16_t SYNC = 0xAA41;  // command frame
    netmemcpy(&buf[len], (const void*) &SYNC, sizeof SYNC);
    len += sizeof SYNC;

    FRAMESIZE_ptr = &buf[len];  // remember FRAMESIZE location for later
    len += sizeof FRAMESIZE;

    uint16_t IDCODE = 2;
    netmemcpy(&buf[len], (const void*) &IDCODE, sizeof IDCODE);
    len += sizeof IDCODE;

    netmemcpy(&buf[len], (const void*)&SOC_recv, sizeof SOC_recv);
    len += sizeof SOC_recv;

    uint32_t FRACSEC = 0;
    netmemcpy(&buf[len], (const void*) &FRACSEC, sizeof FRACSEC);
    len += sizeof FRACSEC;

    netmemcpy(&buf[len], (const void*) &transmission_state, sizeof transmission_state);
    len += sizeof transmission_state;

    FRAMESIZE = len + 2;    // includes CRC size
    netmemcpy(FRAMESIZE_ptr, (const void*) &FRAMESIZE, sizeof FRAMESIZE);

    uint16_t crc = ComputeCRC(buf, len);
    netmemcpy(&buf[len], (unsigned char *) &crc, sizeof crc);
    len += sizeof crc;

    return len;
};

uint16_t write_ethernet_frame_into_buf(unsigned char *buf, uint32_t SOC_recv, uint16_t transmission_state) {
    uint16_t len_out = 0;
    uint16_t len_payload = 0;

    len_payload = write_data_transmission_frame(buf_payload, SOC_recv, transmission_state);

    len_out = encode_UDP(buf, &udp, (const char*)buf_payload, len_payload);

    return len_out;
};







//// Here are the port definitions required by ethernet. This port assignment
//// is for the L16 sliceKIT with the ethernet slice plugged into the
//// CIRCLE slot.
//port p_eth_rxclk = on tile[1]: XS1_PORT_1J;
//port p_eth_rxd = on tile[1]: XS1_PORT_4E;
//port p_eth_txd = on tile[1]: XS1_PORT_4F;
//port p_eth_rxdv = on tile[1]: XS1_PORT_1K;
//port p_eth_txen = on tile[1]: XS1_PORT_1L;
//port p_eth_txclk = on tile[1]: XS1_PORT_1I;
//port p_eth_rxerr = on tile[1]: XS1_PORT_1P;
//port p_eth_dummy = on tile[1]: XS1_PORT_8C;
//clock eth_rxclk = on tile[1]: XS1_CLKBLK_1;
//clock eth_txclk = on tile[1]: XS1_CLKBLK_2;
//
//
//port p_smi_mdio = on tile[1]: XS1_PORT_1M;
//port p_smi_mdc = on tile[1]: XS1_PORT_1N;
//
//// These ports are for accessing the OTP memory
////otp_ports_t otp_ports = on tile[0]: OTP_PORTS_INITIALIZER;




//void xscope_user_init(void) {
//
//#if 0
//  xscope_register(3, XSCOPE_CONTINUOUS, "local_egress_ts", XSCOPE_UINT, "Value",
//    XSCOPE_CONTINUOUS, "received_sync_ts", XSCOPE_INT, "Value",
//    XSCOPE_CONTINUOUS, "residence", XSCOPE_INT, "Value");
///*
//  xscope_register(4, XSCOPE_CONTINUOUS, "rdptr", XSCOPE_UINT, "Value",
//    XSCOPE_CONTINUOUS, "wrptr", XSCOPE_UINT, "Value",
//    XSCOPE_CONTINUOUS, "hdr", XSCOPE_UINT, "Value",
//    XSCOPE_CONTINUOUS, "hdr->next", XSCOPE_INT, "Value");
//*/
///*
//  xscope_register(2, XSCOPE_CONTINUOUS, "commit", XSCOPE_UINT, "Value",
//    XSCOPE_CONTINUOUS, "buf", XSCOPE_INT, "Value");
//*/
//    // XSCOPE_CONTINUOUS, "buf", XSCOPE_INT, "Value");
//    // XSCOPE_CONTINUOUS, "fwdbuf", XSCOPE_INT, "Value");
//#else
//  xscope_register(0);
//#endif
//  xscope_config_io(XSCOPE_IO_BASIC);
//}

on ETHERNET_DEFAULT_TILE: otp_ports_t otp_ports = OTP_PORTS_INITIALIZER;

smi_interface_t smi1 = ETHERNET_DEFAULT_SMI_INIT;

// Circle slot
mii_interface_t mii1 = ETHERNET_DEFAULT_MII_INIT;

// Square slot
on tile[1]: mii_interface_t mii2 = {
  XS1_CLKBLK_3,
  XS1_CLKBLK_4,
  XS1_PORT_1B,
  XS1_PORT_4D,
  XS1_PORT_4A,
  XS1_PORT_1C,
  XS1_PORT_1G,
  XS1_PORT_1F,
  XS1_PORT_4B
};

// PTP sync port
on stdcore[0]: port ptp_sync_port = XS1_PORT_1C;//XS1_PORT_4A;




#define NORMAL_PORT     0   // rx on this port is tx'd normally
#define DELAYED_PORT    1   // rx on this port is tx'd with delay


//#define PTP_PERIODIC_TIME (50000)




int in_byte_counter = 0;
int out_byte_counter = 0;
//#define MAX_DELAY_MESG_LENGTH   (1000 + (8*8))        // TODO define max packet size
#define MAX_DELAY_MESG_LENGTH   1024        // TODO define max packet size
#define MAX_BUF_LENGTH  5

typedef struct delay_buf {
    unsigned int buf[MAX_DELAY_MESG_LENGTH / 4];
//    unsigned char buf[MAX_DELAY_MESG_LENGTH];
    unsigned len;
    unsigned rx_ts;
    unsigned src_port;
    unsigned to_send;
} delay_buf_t;

delay_buf_t delay_buffer[MAX_BUF_LENGTH];

unsigned int next_free_buf = 0;
unsigned int start_replay = 0;
//unsigned int next_emptiable_buf = -1;


#pragma select handler
void delay_recv_and_process_packet(chanend c_rx, chanend c_tx) {
//    unsigned ts;
//    unsigned src_port;
//    unsigned len;
    //  unsigned int buf[MAX_DELAY_MESG_LENGTH / 4];

//    if (next_free_buf == next_emptiable_buf) {
//        debug_printf("buffer overflow\n");
//    }
//    else {
      safe_mac_rx_timed(c_rx,
    //          (buf, unsigned char[]),
                      (delay_buffer[next_free_buf].buf, unsigned char[]),
                      delay_buffer[next_free_buf].len,
                      delay_buffer[next_free_buf].rx_ts,
                      delay_buffer[next_free_buf].src_port,
                       MAX_DELAY_MESG_LENGTH);

      delay_buffer[next_free_buf].to_send = 1;

//      debug_printf("next_free_buf %d\n", next_free_buf);
      in_byte_counter += delay_buffer[next_free_buf].len;
//      xscope_int(IN_BYTE_COUNTER, in_byte_counter);
//    }

//  debug_printf("RX %d bytes, port %d; total %d bytes\n", delay_buffer[next_free_buf].len, delay_buffer[next_free_buf].src_port, in_byte_counter);


      next_free_buf++;
      if (next_free_buf >= MAX_BUF_LENGTH) {
          next_free_buf = 0;
          start_replay = 1;
      }


//  // TODO do something with buf contents
//  if (src_port == NORMAL_PORT) {
//      unsigned int sentTime;
//      mac_tx_timed(c_tx, buf, len, sentTime, DELAYED_PORT);    // TODO check ptp_tx_timed() implementation
//
//      // TODO do something with sentTime and ts
////      debug_printf("  TX %d bytes, port %d, t %d us\n", len, DELAYED_PORT, (sentTime - ts) / 10);
////      debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, DELAYED_PORT, len, (sentTime - ts) / 10);
//
//      int duration_us = (sentTime - ts) / 10;
//      if (duration_us > 500) {
//          debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, DELAYED_PORT, len, duration_us);
//      }
//  }
//  else if (src_port == DELAYED_PORT) {
//      unsigned int sentTime;
//      mac_tx_timed(c_tx, buf, len, sentTime, NORMAL_PORT);    // TODO check ptp_tx_timed() implementation
//
//      // TODO do something with sentTime and ts
////      debug_printf("  TX %d bytes, port %d, t %d us\n", len, NORMAL_PORT, (sentTime - ts) / 10);
////      debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, NORMAL_PORT, len, (sentTime - ts) / 10);
//
//      int duration_us = (sentTime - ts) / 10;
//      if (duration_us > 500) {
//          debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, NORMAL_PORT, len, duration_us);
//      }
//  }


  if (start_replay == 1) {
          unsigned int buf_to_forward = next_free_buf;//(next_free_buf + (MAX_BUF_LENGTH - 2)) % MAX_BUF_LENGTH;
      //    debug_printf("next_free_buf %d, buf_to_forward %d\n", next_free_buf, buf_to_forward);

          if (delay_buffer[buf_to_forward].src_port == DELAYED_PORT) {
              if (delay_buffer[buf_to_forward].to_send == 1) {
                  unsigned int sentTime;
                  mac_tx_timed(c_tx, delay_buffer[buf_to_forward].buf, delay_buffer[buf_to_forward].len, sentTime, NORMAL_PORT);    // TODO check ptp_tx_timed() implementation
                  delay_buffer[buf_to_forward].to_send = 0;

                  // TODO do something with sentTime and ts
                  //      debug_printf("  TX %d bytes, port %d, t %d us\n", len, NORMAL_PORT, (sentTime - ts) / 10);
                  //      debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, NORMAL_PORT, len, (sentTime - ts) / 10);

                  out_byte_counter += delay_buffer[buf_to_forward].len;
      //            xscope_int(OUT_BYTE_COUNTER, out_byte_counter);


                  int duration_us = (sentTime - delay_buffer[buf_to_forward].rx_ts) / 100;
                  xscope_int(FRAME_DELAY, duration_us);
          //            if (duration_us > 500) {
      //                debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", delay_buffer[buf_to_forward].src_port, NORMAL_PORT, delay_buffer[buf_to_forward].len, duration_us);
          //            }
              }
              else {
                  debug_printf("found buffer already sent\n");
              }
          }
          else {
              debug_printf("unexpected source port %d\n", delay_buffer[buf_to_forward].src_port);
          }
      }



//  ptp_recv(c_tx, (buf, unsigned char[]), ts, src_port, len);
}


void periodic(chanend c_tx) {
    if (start_replay == 1) {
        unsigned int buf_to_forward = next_free_buf;//(next_free_buf + (MAX_BUF_LENGTH - 2)) % MAX_BUF_LENGTH;
    //    debug_printf("next_free_buf %d, buf_to_forward %d\n", next_free_buf, buf_to_forward);

        if (delay_buffer[buf_to_forward].src_port == DELAYED_PORT) {
            if (delay_buffer[buf_to_forward].to_send == 1) {
                unsigned int sentTime;
                mac_tx_timed(c_tx, delay_buffer[buf_to_forward].buf, delay_buffer[buf_to_forward].len, sentTime, NORMAL_PORT);    // TODO check ptp_tx_timed() implementation
                delay_buffer[buf_to_forward].to_send = 0;

                // TODO do something with sentTime and ts
                //      debug_printf("  TX %d bytes, port %d, t %d us\n", len, NORMAL_PORT, (sentTime - ts) / 10);
                //      debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", src_port, NORMAL_PORT, len, (sentTime - ts) / 10);

                out_byte_counter += delay_buffer[buf_to_forward].len;
    //            xscope_int(OUT_BYTE_COUNTER, out_byte_counter);


                int duration_us = (sentTime - delay_buffer[buf_to_forward].rx_ts) / 100;
                xscope_int(FRAME_DELAY, duration_us);
        //            if (duration_us > 500) {
    //                debug_printf("arrived on port %d, sent on port %d, TX %d bytes, t %d us\n", delay_buffer[buf_to_forward].src_port, NORMAL_PORT, delay_buffer[buf_to_forward].len, duration_us);
        //            }
            }
        }
        else {
            debug_printf("unexpected source port %d\n", delay_buffer[buf_to_forward].src_port);
        }
    }
}



void delay_server(chanend c_rx, chanend c_tx) {
  timer ptp_timer;
  int ptp_timeout;

//  mac_set_custom_filter(c_rx, MAC_FILTER_PTP);
  mac_set_custom_filter(c_rx, 0xFFFFFFFF);
  ptp_timer :> ptp_timeout;

  while (1) {
    [[ordered]]
    select {
//        case ptp_timer when timerafter(ptp_timeout) :> void:
//            periodic(c_tx);
//    //            ptp_periodic(c_tx, ptp_timeout);
//            ptp_timeout += PTP_PERIODIC_TIME;
//            break;
        case delay_recv_and_process_packet(c_rx, c_tx):
            break;
      }
  }
}



void delay_server_test() {
  timer ptp_timer;
//  timer delay_flag_timer;
  unsigned int ptp_timeout;
//  unsigned int delay_flag_timeout;
  unsigned int delay_flag = 0;
  int len = 0;
//  random_generator_t gen = random_create_generator_from_seed(12345);

//  mac_set_custom_filter(c_rx, MAC_FILTER_PTP);
//  mac_set_custom_filter(c_rx, 0x1000);
  ptp_timer :> ptp_timeout;

  debug_printf("start: %d bytes\n", len);

  while (1) {
    [[ordered]]
    select {
        case ptp_timer when timerafter(ptp_timeout) :> void:
//            unsigned rand = random_get_random_number(gen);
//            periodic_queue_tx(c_tx, rand);
//            periodic_queue_tx_check_all(c_tx);
    //            ptp_periodic(c_tx, ptp_timeout);
            ptp_timeout += 100000000;

            delay_flag = 1;
            xscope_int(DELAY_FLAG, delay_flag);

//            set_UDP_dest(&udp, ip, &mac_add[0], remote_port);
//            len = write_ethernet_frame_into_buf(buf, 0, 2);

            debug_printf("generated %d bytes\n", len);

            delay_flag = 0;
            xscope_int(DELAY_FLAG, delay_flag);

            break;
        default:
            break;
      }
  }
}


#define ETH_RX_BUFFER_SIZE_WORDS 1600


int main()
{
    chan c_mac_rx[1], c_mac_tx[1];
//    chan c_mac_rx2[1], c_mac_tx2[1];
  chan c_ptp[1];
//  chan connect_status;

//  ethernet_cfg_if i_cfg[1];
//  ethernet_rx_if i_rx[1];
//  ethernet_tx_if i_tx[1];
//  smi_if i_smi;


  par
  {
    on ETHERNET_DEFAULT_TILE:
    {
        char mac_address[6];
        char mac_address2[6];
        otp_board_info_get_mac(otp_ports, 0, mac_address);
      smi_init(smi1);
      eth_phy_config(1, smi1);
      ethernet_server_full_two_port(mii1,
                                    mii2,
                                    smi1,
                                    null,
                                    mac_address,
                                    c_mac_rx, 1,
                                    c_mac_tx, 1);
//      ethernet_server(mii1, smi1, mac_address, c_mac_rx, 1, c_mac_tx, 1);
//      ethernet_server(mii2, smi2, mac_address, c_mac_rx2, 1, c_mac_tx2, 1);
    }
//
//
//    on stdcore[0]: delay_server(c_mac_rx[0], c_mac_tx[0]);


//      on tile[1]: mii_ethernet_mac(i_cfg, 1,
//                                  i_rx, 1,
//                                  i_tx, 1,
//                                  p_eth_rxclk, p_eth_rxerr,
//                                  p_eth_rxd, p_eth_rxdv,
//                                  p_eth_txclk, p_eth_txen, p_eth_txd,
//                                  p_eth_dummy,
//                                  eth_rxclk, eth_txclk,
//                                  ETH_RX_BUFFER_SIZE_WORDS);
//      on tile[1]: lan8710a_phy_driver(i_smi, i_cfg[CFG_TO_PHY_DRIVER]);
//      on tile[1]: smi(i_smi, p_smi_mdio, p_smi_mdc);


    // enable both these tasks for a PTP server:
    on stdcore[1]: ptp_server(c_mac_rx[0],
                              c_mac_tx[0],
                              c_ptp,
                              1,
                              PTP_SLAVE_ONLY);
    on stdcore[0]: ptp_output_test_clock(c_ptp[0], ptp_sync_port, 100000000);


    on stdcore[0]: delay_server_test();
  }

  return 0;
}
