**Lab 4: WiFi Security -- Passive Sniffing and Man-in-the-Middle Attacks**

**CprE 5370 -- Cyber Security for Cyber-Physical and IoT Systems**

**Lab Overview**

In this lab, you will explore two fundamental WiFi security attack techniques using the COSMOS wireless testbed:

- **Part 1 -- Passive Sniffing:** You will observe the level of confidentiality provided by three types of 802.11 WiFi networks (Open, WEP, and WPA) by performing passive sniffing attacks and analyzing captured traffic in Wireshark.

- **Part 2 -- Man-in-the-Middle (MiTM) Attack:** You will carry out an active ARP spoofing attack on a WPA-protected WiFi network to intercept communications, and compare the security of encrypted vs. unencrypted application-layer protocols (FTP vs. SFTP, Telnet vs. SSH).

**Estimated Duration:** This combined lab is expected to take approximately 3--4 hours. You may need to reserve multiple 2-hour slots on the COSMOS testbed.

**Prerequisites:**

- Download and install [Wireshark](https://www.wireshark.org/download.html) on your local machine before starting the lab.

![Wireshark Download Page](figures/fig_wireshark_download.jpeg)

- You can execute this lab on Windows, Linux, or Mac, but **Linux is recommended**. You can visit https://it.engineering.iastate.edu/remote-computing/ for information on how to connect remotely to the ISU Linux machines.

# Testbed Setup (Common to Both Parts)

In this lab, you will use a wireless testbed called **COSMOS**. COSMOS is a wireless network testbed that provides programmable radio nodes for controlled experimentation. Both parts of this lab use the **same four nodes** with the same roles, so you only need to set up the testbed once.

## Step 1: Create a COSMOS Account

1. If you do not already have a COSMOS account, register at https://www.cosmos-lab.org/portal/register

2. Select your organizational group from the dropdown menu and provide your contact information.

3. Confirm your request via the email you receive (within 30 minutes).

4. Wait for approval from your group's principal investigator.

> **Note:** If you already have an ORBIT account, you can use the same credentials -- COSMOS and ORBIT share the same account system.

The COSMOS portal dashboard looks similar to the following:

![COSMOS Portal Dashboard](figures/fig_cosmos_dashboard.png)

## Step 2: Upload SSH Keys

You will need SSH keys to access the testbed nodes. SSH access uses **public key authentication only** -- password-based SSH is not permitted.

1. Generate an RSA key pair (if you don't already have one):

```
ssh-keygen -t rsa
```

2. Log in to the COSMOS portal at https://www.cosmos-lab.org/portal/dashboard

3. On the Dashboard, click **SSH Keys** and upload your public key file (the `.pub` file).

> **Important:** Do NOT delete the auto-generated default public key (ending with `@internal1`) -- it is used for internal network access.

## Step 3: Reserve the Testbed

1. Navigate to the scheduler at https://www.cosmos-lab.org/portal/scheduler

2. Click on the time slot you want to use on the **sb4** row (listed as `sb4.orbit-lab.org`).

3. Configure your reservation start/end time and submit.

> **Note:** You may need to reserve multiple slots to complete both parts of this lab. Check the scheduler for current maximum reservation limits.

The scheduler interface looks similar to the following:

![Testbed Scheduler](figures/fig_cosmos_scheduler.png)

## Step 4: Access the Testbed Console

At your reserved time, SSH to your testbed console:

```
ssh your_username@sb4.orbit-lab.org
```

Replace `your_username` with your COSMOS/ORBIT username. Your terminal should look similar to:

![Terminal SSH Login](figures/fig_cosmos_console.png)

## Step 5: Prepare the Testbed

For this experiment, we need a group of **four neighboring nodes** that have an **Atheros 5000X wireless card**. In the instructions that follow, we use **node1-1, node1-2, node1-7, and node1-8** on the sb4 testbed, which are known to be reliable. Node1-9 is also available as a spare. If any of these are not available, substitute other nodes on sb4.

### Using Cosmos Core (Recommended)

**Cosmos Core** is an automation tool that handles node initialization (attenuation matrix reset, disk imaging, power-on, and reachability verification) through an interactive menu. The entire process typically takes **under 10 minutes**. To use it:

1. On the testbed console, clone the Cosmos Core repository and launch it:

```
git clone https://github.com/shahabafshar/cosmos-core.git
cd cosmos-core
chmod +x *.sh scripts/*.sh
./main.sh
```

You should see the Cosmos Core interactive menu:

![Cosmos Core Menu](figures/fig_cosmos_core_menu.png)

2. Choose option **1 (Select nodes)** to open the node selection screen. Use arrow keys to navigate and **Space** to toggle nodes.

   ![Cosmos Core Node Selection](figures/fig_cosmos_core_nodes.png)

   > **Note:** Cosmos Core comes with a pre-configured set of nodes based on the most recent successful run. As of this writing, **node1-1, node1-2, node1-7, node1-8, and node1-9** are the known working nodes (selected by default), while node1-3 through node1-6 have had hardware issues. You are free to modify this selection and try other nodes, but keep in mind that node availability may change over time. If a node fails during initialization, Cosmos Core will automatically exclude it and mark it with `[!]`. You can press **r** to clear failures and retry, or simply proceed with the nodes that succeeded.

   You need **at least four working nodes** for this lab. Press **s** to save your selection.

3. Choose option **2 (Initialize selected nodes)**. Cosmos Core will automatically:
   - Power off all nodes in the grid
   - Reset the attenuation matrix to zero attenuation
   - Load the `wifi-experiment.ndz` disk image onto your selected nodes
   - Power on the nodes
   - Verify that all nodes are reachable

   Wait for the initialization summary to appear. It will show which nodes succeeded and which (if any) failed. If any of your chosen nodes fail, you can go back to option **1**, select different nodes (or press **r** to refresh and retry), and run initialization again.

4. *(Optional)* Choose option **3 (Setup selected nodes)** to clean up stale processes and install additional packages on the nodes.

[Take a screenshot of the Cosmos Core initialization summary showing successful node setup.]{.mark}

You can verify your nodes are reachable at any time by choosing option **4 (Check selected nodes)**:

![Cosmos Core Check](figures/fig_cosmos_core_check.png)

Once you have at least four successfully initialized nodes, choose option **7 (Exit)** and proceed to Step 6. Note which nodes succeeded and use those as your AP, Alice, Bob, and Mallory.

### Manual Method (Alternative)

If Cosmos Core is not available or you encounter issues, you can prepare the testbed manually by running the following commands on the testbed console.

Reset the programmable attenuation matrix to zero attenuation between all pairs of nodes:

```
wget -qO- "http://internal2dmz.orbit-lab.org:5054/instr/setAll?att=0"

wget -qO- "http://internal2dmz.orbit-lab.org:5054/instr/selDevice?switch=3&port=1"
wget -qO- "http://internal2dmz.orbit-lab.org:5054/instr/selDevice?switch=4&port=1"
wget -qO- "http://internal2dmz.orbit-lab.org:5054/instr/selDevice?switch=5&port=1"
wget -qO- "http://internal2dmz.orbit-lab.org:5054/instr/selDevice?switch=6&port=1"
```

Load the disk image onto the four nodes:

```
omf load -i wifi-experiment.ndz -t node1-1.sb4.orbit-lab.org,node1-2.sb4.orbit-lab.org,node1-7.sb4.orbit-lab.org,node1-8.sb4.orbit-lab.org
```

[Take a screenshot of the successful disk image loading output.]{.mark}

When the disk image has finished loading, power on the nodes:

```
omf tell -a on -t node1-1.sb4.orbit-lab.org,node1-2.sb4.orbit-lab.org,node1-7.sb4.orbit-lab.org,node1-8.sb4.orbit-lab.org
```

[Take a screenshot showing the nodes powered on.]{.mark}

## Step 6: Open SSH Sessions and Assign Roles

Wait a few minutes for your nodes to boot. Then, open terminal windows and SSH to your testbed console (`sb4.orbit-lab.org`). You will need **four terminals** for Part 1 (one per node). For Part 2, you will need **six terminals total**: one each for AP, Alice, and Bob, plus three for Mallory. You may open all six now or add the two extra Mallory terminals when you reach Part 2.

Of the four nodes, designate:

| Role | Description | Suggested Node |
|---|---|---|
| **AP** | Access Point | node1-1 |
| **Alice** | Client / Victim | node1-2 |
| **Bob** | Client / Server | node1-7 |
| **Mallory** | Attacker | node1-8 |

In each SSH terminal, connect to the assigned node as the root user. For example:

```
ssh root@node1-1
```

> **Note:** For Part 2, you will need **three** terminals connected to Mallory (for ARP spoofing + Ettercap). The six terminals total are: 1 for AP, 1 for Alice, 1 for Bob, and 3 for Mallory.

[Take a screenshot showing your SSH sessions connected to the testbed nodes.]{.mark}

# Part 1: Passive Sniffing in 802.11 Networks

In this part, Mallory will attempt to **passively sniff** communications between Alice and Bob across three different WiFi network configurations. You will observe how different WiFi security protocols affect an attacker's ability to read captured traffic.

## Part 1A: Open WiFi Network

**Step 1:** On the **AP** node, create a file `hostapd-open.conf` with the following contents:

```
interface=wlan0
driver=nl80211
ssid=wifi-open
hw_mode=g
channel=6
```

Then start the AP:

```
hostapd hostapd-open.conf
```

[Take a screenshot of the AP terminal showing the hostapd startup.]{.mark}

**Step 2:** On **Alice** and **Bob**, connect to the open network:

```
ifconfig wlan0 up
iwconfig wlan0 mode managed
iwconfig wlan0 essid "wifi-open"
```

Watch the AP terminal -- you should see an `AP-STA-CONNECTED` message (with the client's MAC address) for each client. Verify the connection on each client:

```
iwconfig wlan0
```

Look for the indication that they are connected to ESSID `wifi-open`.

**Step 3:** Assign IP addresses:

On Alice:
```
ifconfig wlan0 192.168.0.3
```

On Bob:
```
ifconfig wlan0 192.168.0.4
```

**Step 4:** On **Mallory**, put the wireless interface into monitor mode:

```
airmon-ng start wlan0
```

> **Note:** The monitor interface created is typically named `mon0`. On some systems it may be named `wlan0mon` instead -- check the `airmon-ng` output and use whichever name is shown in all subsequent `airodump-ng` commands.

Then start capturing traffic:

```
airodump-ng mon0 --bssid <AP_MAC_ADDRESS> --channel 6 -w wifi-open -o pcap
```

> Replace `<AP_MAC_ADDRESS>` with the actual MAC address of the AP. You can find it by running `iwconfig wlan0` on Alice or Bob and noting the "Access Point" field.

[Take a screenshot of Mallory's airodump-ng capture running.]{.mark}

**Step 5:** Exchange messages between Alice and Bob. On **Bob**, run:

```
netcat -l 4000
```

On **Alice**, run:

```
netcat 192.168.0.4 4000
```

Type a message in either terminal and press Enter. You should see your message appear on the other host.

[Take a screenshot of the netcat message exchange.]{.mark}

**Step 6:** Use Ctrl+C to stop `airodump-ng` on Mallory, `netcat` on Alice and Bob, and `hostapd` on the AP. **Do not** run `airmon-ng stop` on Mallory -- you will need the monitor interface for Parts 1B and 1C. On the Mallory node, you should have a file named `wifi-open-01.cap`. Transfer this file to your local machine using `scp`:

> **Note:** To retrieve a file from a testbed node, use `scp` in two steps:
>
> 1) First, from the testbed console, transfer the file from the node to your home directory on the console:
> ```
> scp root@node1-8:/root/wifi-open-01.cap ~/wifi-open-01.cap
> ```
>
> 2) Then, from your own device, transfer the file from the console to your device:
> ```
> scp your_username@sb4.orbit-lab.org:~/wifi-open-01.cap wifi-open-01.cap
> ```

Open the file in Wireshark.

[**Question 1:** Look for the data packets containing the secret message -- is the attacker, who is not connected to the network, able to see the data in plaintext? (Use the Wireshark filter bar to filter on Alice's and Bob's MAC addresses, to more easily find the relevant packets.) Take a screenshot of the Wireshark capture showing the plaintext data.]{.mark}

## Part 1B: WEP Network

> **Before starting:** Ensure that `hostapd` from Part 1A has been stopped (Ctrl+C in the AP terminal). On **Alice** and **Bob**, run `ifconfig wlan0 down` to fully disconnect from the previous network.

**Step 1:** On the **AP** node, create a file `hostapd-wep.conf` with the following contents:

```
interface=wlan0
driver=nl80211
ssid=wifi-wep
hw_mode=g
channel=6
auth_algs=2
wep_default_key=0
wep_key0="12345"
```

Then start the AP:

```
hostapd hostapd-wep.conf
```

**Step 2:** On **Alice** and **Bob**, connect to the WEP network:

```
ifconfig wlan0 up
iwconfig wlan0 mode managed
iwconfig wlan0 essid "wifi-wep"
iwconfig wlan0 key s:12345
iwconfig wlan0 ap <AP_MAC_ADDRESS>
```

> Replace `<AP_MAC_ADDRESS>` with the AP's BSSID.

Watch the AP terminal for the `AP-STA-CONNECTED` messages, then assign IP addresses:

On Alice: `ifconfig wlan0 192.168.0.3`

On Bob: `ifconfig wlan0 192.168.0.4`

**Step 3:** On **Mallory**, the wireless interface should still be in monitor mode from Part 1A. Start capturing:

```
airodump-ng mon0 --bssid <AP_MAC_ADDRESS> --channel 6 -w wifi-wep -o pcap
```

**Step 4:** Exchange messages between Alice and Bob using `netcat` (same as Part 1A -- Bob listens on port 4000, Alice connects).

**Step 5:** Stop all processes with Ctrl+C. Transfer `wifi-wep-01.cap` to your local machine and open it in Wireshark.

[**Question 2:** Is the attacker able to see the data in plaintext when the attacker does not know the WEP key? Take a screenshot of the Wireshark capture showing the encrypted WEP data.]{.mark}

[**Question 3:** If the attacker later finds out the WEP key, will she be able to decrypt the traffic?]{.mark}

**Step 6:** Add the WEP key to Wireshark to test decryption:

1. Open **Edit > Preferences**
2. In the **Protocols** section, choose **IEEE 802.11**
3. Click **Edit** next to **Decryption Keys**
4. Click **+** to add a new key
5. Set the type to **wep** and enter the key in hex format: `31:32:33:34:35`

Your Wireshark decryption keys dialog should look like this:

![Wireshark WEP Decryption Key](figures/fig_wireshark_wep_key.jpeg)

*Figure 1: Adding the WEP key in Wireshark's decryption keys dialog.*

6. Click OK, close Wireshark, and re-open the capture file

[Look for a "Decrypted WEP data" tab on the bottom panel. Take a screenshot showing the decrypted message. Can the attacker now read the data?]{.mark}

## Part 1C: WPA Network

> **Before starting:** Ensure that `hostapd` from Part 1B has been stopped (Ctrl+C in the AP terminal). On **Alice** and **Bob**, run `ifconfig wlan0 down` to fully disconnect from the previous network.

**Step 1:** On the **AP** node, create a file `hostapd-wpa.conf` with the following contents:

```
interface=wlan0
driver=nl80211
ssid=wifi-wpa
hw_mode=g
channel=6
auth_algs=1
wpa=1
wpa_key_mgmt=WPA-PSK
wpa_passphrase=123456789
```

Then start the AP:

```
hostapd hostapd-wpa.conf
```

**Step 2:** On **Alice** and **Bob**, generate the WPA configuration and connect:

```
wpa_passphrase wifi-wpa 123456789 > wpa.conf
```

Inspect the generated configuration:

```
cat wpa.conf
```

You should see:

```
network={
    ssid="wifi-wpa"
    #psk="123456789"
    psk=ebe5f11342aedef8edcf53317352a6ac89699c9a0a5cc5c823101012590de6bb
}
```

Connect to the network:

```
ifconfig wlan0 up
wpa_supplicant -iwlan0 -cwpa.conf -B
```

> **Note:** The WPA supplicant utility will remain running as a background process and will attempt to reconnect if disconnected. **Do not run it more than once** -- having two supplicants running simultaneously will cause connectivity issues.

Watch for the `AP-STA-CONNECTED` message on the AP, then assign IP addresses as before (Alice: 192.168.0.3, Bob: 192.168.0.4).

**Step 3:** On **Mallory**, start capturing:

```
airodump-ng mon0 --bssid <AP_MAC_ADDRESS> --channel 6 -w wifi-wpa -o pcap
```

**Step 4:** Exchange messages between Alice and Bob using `netcat`.

**Step 5:** Stop all processes. Transfer `wifi-wpa-01.cap` to your local machine.

[**Question 4:** Is the attacker able to see the data in plaintext?]{.mark}

**Step 6:** Add the WPA key to Wireshark:

1. Open the **Decryption Keys** menu (Edit > Preferences > Protocols > IEEE 802.11 > Decryption Keys)
2. Click **+** and add a key with type **wpa-psk** and value: `ebe5f11342aedef8edcf53317352a6ac89699c9a0a5cc5c823101012590de6bb`

   > Alternatively, in some Wireshark versions you can use type **wpa-pwd** with value `123456789:wifi-wpa` (passphrase:SSID). Both approaches produce the same result.

Your decryption keys dialog should now show both the WEP and WPA keys:

![Wireshark WPA Decryption Key](figures/fig_wireshark_wpa_key.png)

*Figure 2: Adding the WPA-PSK key in Wireshark's decryption keys dialog.*

3. Press OK and re-open the WPA capture file.

[**Question 5:** Is Mallory able to read the message in plaintext, even with the WPA key added? Take a screenshot of the Wireshark capture showing that the WPA data remains encrypted.]{.mark}

### Capturing the 4-Way Handshake

In a WPA network, an attacker needs to have captured the client's **4-way handshake** in order to decrypt data sent over the network. Let's try again in a scenario where Mallory starts capturing **before** Alice and Bob join.

**Step 7:** On **Alice** and **Bob**, stop the WPA supplicant:

```
killall wpa_supplicant
```

**Step 8:** On **Mallory**, start a new capture:

```
airodump-ng mon0 --bssid <AP_MAC_ADDRESS> --channel 6 -w wifi-wpa-with-handshake -o pcap
```

**Step 9:** On the **AP**, stop the running hostapd (Ctrl+C) and restart it:

```
hostapd hostapd-wpa.conf
```

**Step 10:** On **Alice** and **Bob**, reconnect:

```
wpa_supplicant -iwlan0 -cwpa.conf -B
```

Watch for the `AP-STA-CONNECTED` messages on the AP.

Reassign IP addresses:

On Alice: `ifconfig wlan0 192.168.0.3`

On Bob: `ifconfig wlan0 192.168.0.4`

**Step 11:** Exchange messages between Alice and Bob using `netcat` again. Then stop all processes.

**Step 12:** Transfer `wifi-wpa-with-handshake-01.cap` to your local machine and open it in Wireshark.

First, use the Wireshark filter `eapol` and verify that the 4-way handshake packets were captured (you should see "Message 1 of 4", "Message 2 of 4", etc.). Your results should look similar to:

![EAPOL 4-Way Handshake](figures/fig_wireshark_eapol_handshake.png)

*Figure 3: Wireshark EAPOL filter showing the captured 4-way handshake between AP and clients.*

[Take a screenshot of the EAPOL filter results showing the captured 4-way handshake.]{.mark}

[**Question 6:** Look for the data packets containing the secret message and specifically look for a "Decrypted TKIP data" tab on the bottom -- is Mallory able to read the data now that she has captured the 4-way handshakes? Take a screenshot.]{.mark}

### Part 1 Analysis Questions

[**Question 7:** Why is knowledge of the key alone sufficient to decrypt traffic in a WEP network, but not in a WPA network? Explain the differences between the encryption keys used in WEP and WPA.]{.mark}

[**Question 8:** Why does capturing the 4-way handshake help the attacker with knowledge of the WPA key decrypt the WPA traffic? What information from the 4-way handshake does the attacker need, and how is that information used?]{.mark}

# Part 2: Man-in-the-Middle Attack on a WiFi Hotspot

In this part, you will carry out an **active** man-in-the-middle attack using ARP spoofing. While Part 1 demonstrated passive eavesdropping, Part 2 shows how an attacker can intercept traffic even on a WPA-protected network by exploiting the ARP protocol, and how application-layer encryption defends against such attacks.

## Background

A **Man-in-the-Middle (MiTM) attack** is one where the attacker (Mallory) secretly captures and relays communication between two parties (Alice and Bob) who believe they are communicating directly with each other.

![MiTM Attack Concept](figures/fig_mitm_concept.png)

*Figure 4: Man-in-the-Middle attack concept. Alice and Bob believe they are communicating directly via the AP, but Mallory intercepts and relays all traffic.*

When data is sent over a WiFi network using WPA-PSK or WPA2-PSK security, it is encrypted at Layer 2 with per-client, per-session keys, and may only be decrypted by its destination. Other clients on the same access point can capture the traffic but can't necessarily decrypt it.

The attack in this part uses a technique known as **ARP spoofing** (or ARP poisoning):

1. Mallory sends gratuitous ARP messages to **Alice**, claiming that Mallory's MAC address is the physical address for Bob's IP.
2. Mallory sends similar ARP messages to **Bob**, claiming that Mallory's MAC address is the physical address for Alice's IP.
3. Alice and Bob unknowingly send all their traffic through Mallory.
4. Mallory forwards the traffic so neither side notices the interception.

A single packet from Alice to Bob is transmitted over the air **four times** during this attack, each time with different addresses in the 802.11 Layer 2 header:

**Step 1 -- Alice → AP:** Alice sends the packet with Mallory's MAC as the destination (since Alice believes this to be Bob's MAC), and the AP's MAC as the receiver:

![Header Step 1](figures/fig_mitm_header1.png)

**Step 2 -- AP → Mallory:** The AP forwards to Mallory (the apparent destination). Since the AP treats Mallory as the final destination, it uses **Mallory's key** to encrypt the packet -- so Mallory can decrypt and read its contents:

![Header Step 2](figures/fig_mitm_header2.png)

**Step 3 -- Mallory → AP:** Mallory forwards the packet toward Bob, with Bob's MAC as the destination:

![Header Step 3](figures/fig_mitm_header3.png)

**Step 4 -- AP → Bob:** The AP retransmits to the actual Bob:

![Header Step 4](figures/fig_mitm_header4.png)

The following diagram shows the complete path of a single packet from Alice to Bob during the MiTM attack, including the 802.11 MAC address fields at each hop:

![MiTM Packet Flow](figures/fig_mitm_packet_flow.png)

*Figure 5: Detailed packet flow during ARP spoofing MiTM attack. Each box shows the Receiver, Destination, Transmitter, and Source MAC addresses in the 802.11 header. Note how the AP uses Mallory's key to encrypt in step 2, allowing Mallory to decrypt and read the contents.*

## Part 2A: Set Up the WPA Network

> **Transitioning from Part 1:** Before starting Part 2, ensure all nodes have a clean state:
>
> 1. On the **AP**, stop hostapd with Ctrl+C.
> 2. On **Alice** and **Bob**, run `killall wpa_supplicant` to stop any WPA supplicant processes.
> 3. On **Mallory**, run `airmon-ng stop mon0` to exit monitor mode and restore the `wlan0` interface. Verify by running `ifconfig wlan0` -- if you see `wlan0` listed, you are ready to proceed. If `wlan0` is not found but `mon0` exists, repeat the `airmon-ng stop mon0` command.
> 4. Open **two additional terminals** connected to Mallory (for a total of three Mallory terminals).

**Step 1:** Configure Bob as an FTP server. On **Bob**, create a user account for Alice:

```
useradd -m alice -s /bin/sh
passwd alice
```

Enter a password for `alice` when prompted. **Remember this password** -- you will use it throughout Part 2. (No characters will appear as you type.)

**Step 2:** On the **AP** node, start the wireless network:

```
ifconfig wlan0 up
create_ap -n wlan0 mitm SECRETPASSWORD
```

This creates an AP with ESSID `mitm` and WPA passphrase `SECRETPASSWORD`.

> **Note:** If `create_ap` is not found on the disk image, consult your TA for an alternative approach.

**Step 3:** On **Alice**, **Bob**, and **Mallory**, connect to the network:

```
ifconfig wlan0 up
iwlist wlan0 scan
```

Verify you can see the `mitm` network, then:

```
wpa_passphrase mitm SECRETPASSWORD > wpa.conf
wpa_supplicant -iwlan0 -cwpa.conf -B
```

> **Note:** Do not run `wpa_supplicant` more than once on any node.

Verify the connection with `iwconfig wlan0`, then assign IP addresses:

- On Alice: `ifconfig wlan0 192.168.0.3`
- On Bob: `ifconfig wlan0 192.168.0.4`
- On Mallory: `ifconfig wlan0 192.168.0.5`

[Record each node's MAC address using `ifconfig wlan0`.]{.mark}

**Step 4:** Verify connectivity -- on each node, ping the other two:

```
ping -c 1 192.168.0.3
ping -c 1 192.168.0.4
ping -c 1 192.168.0.5
```

[Take a screenshot showing successful pings between the nodes.]{.mark}

## Part 2B: Carry Out the ARP Spoofing Attack

**Step 1:** On **Mallory** (Terminal 1), start ARP spoofing toward Alice:

```
arpspoof -i wlan0 -t 192.168.0.3 192.168.0.4
```

**Step 2:** On **Mallory** (Terminal 2), start ARP spoofing toward Bob:

```
arpspoof -i wlan0 -t 192.168.0.4 192.168.0.3
```

You should see output indicating that Mallory is sending gratuitous ARP replies at regular intervals.

[**Question 9:** Take a screenshot of the ARP spoofing output. Comment on what information the `arpspoof` output shows.]{.mark}

**Step 3:** Verify the ARP poisoning. On **Alice**, run:

```
arp -na
```

[**Question 10:** Run `arp -na` on both Alice and Bob. Take screenshots. Verify that Alice's ARP table shows Mallory's MAC address for Bob's IP, and Bob's ARP table shows Mallory's MAC address for Alice's IP. Explain what you observe.]{.mark}

**Step 4:** On **Mallory** (Terminal 3), enable IP forwarding so traffic is relayed transparently:

```
sysctl -w net.ipv4.ip_forward=1
```

> **Note:** This setting is temporary and will be lost if the node reboots or is reset. If you need to restart a node at any point, remember to re-enable IP forwarding before continuing.

**Step 5:** Start the Ettercap sniffer on **Mallory** (Terminal 3):

```
ettercap -T -i wlan0
```

Any interesting traffic passing between Alice and Bob (through Mallory) will appear in the Ettercap output.

## Part 2C: Test FTP (Unencrypted File Transfer)

> **Note:** The `wifi-experiment.ndz` disk image should include an FTP server (vsftpd). If FTP connections fail, you may need to install and start the FTP server on Bob: `apt-get update && apt-get -y install vsftpd && service vsftpd start`

**Step 1:** On **Alice**, start an FTP session to Bob (if the `ftp` command is not found, install it with `apt-get install ftp`):

```
ftp
```

At the FTP prompt, connect to Bob:

```
open 192.168.0.4
```

When prompted, enter the username (`alice`) and the password you set earlier.

**Step 2:** Check the Ettercap window on Mallory. You should see a line like:

```
FTP : 192.168.0.4:21 -> USER: alice  PASS: SeCrEtPaSsWoRd
```

[**Question 11:** Take a screenshot of the Ettercap output showing the captured FTP credentials. Are Alice's username and password visible to Mallory?]{.mark}

## Part 2D: Test SFTP (Encrypted File Transfer)

**Step 1:** Leave Ettercap and both ARP spoofing processes running on Mallory. On **Alice**, run:

```
sftp alice@192.168.0.4
```

When prompted, log in with Alice's password.

[**Question 12:** Take a screenshot of the Ettercap output. Are Alice's credentials visible to Mallory when using SFTP?]{.mark}

## Part 2E: Test Telnet (Unencrypted Remote Login)

**Step 1:** On **Bob**, install and configure the telnet server:

```
apt-get update
apt-get -y install xinetd telnetd
```

**Step 2:** Create the telnet configuration file. On Bob, run `nano /etc/xinetd.d/telnet` and paste the following:

```
# default: on
# description: telnet server
service telnet
{
    disable = no
    flags = REUSE
    socket_type = stream
    wait = no
    user = root
    server = /usr/sbin/in.telnetd
    log_on_failure += USERID
}
```

Save with Ctrl+O and Enter, then exit with Ctrl+X.

**Step 3:** Restart the service on Bob:

```
service xinetd restart
```

**Step 4:** Make sure Ettercap and both ARP spoofing processes are still running on Mallory. On **Alice**, run:

```
telnet 192.168.0.4
```

When prompted, enter the username (`alice`) and password.

[**Question 13:** Take a screenshot of the Ettercap output. Are Alice's credentials captured when using telnet? (Note: credentials may appear one or two letters at a time in separate packets.)]{.mark}

## Part 2F: Test SSH (Encrypted Remote Login)

**Step 1:** On **Alice**, run:

```
ssh alice@192.168.0.4
```

When prompted, enter Alice's password.

[**Question 14:** Take a screenshot of the Ettercap output. Are Alice's credentials captured when using SSH?]{.mark}

## Part 2 Analysis Questions

[**Question 15:** For each of the four applications (FTP, SFTP, Telnet, SSH), explain whether credentials can be captured by a malicious user on an insecure medium (like a public WiFi hotspot). Summarize your findings in the following table:]{.mark}

| Protocol | Type | Encrypted? | Credentials Captured? |
|---|---|---|---|
| FTP | File Transfer | | |
| SFTP | File Transfer | | |
| Telnet | Remote Login | | |
| SSH | Remote Login | | |

[**Question 16:** Based on your results, which file transfer application (FTP or SFTP) is more secure? Which remote login application (Telnet or SSH) is more secure? Explain why.]{.mark}

[**Question 17:** In Part 1, we saw that WPA encryption protects data at Layer 2. In Part 2, Mallory was able to intercept traffic on a WPA network using ARP spoofing. Explain why WPA encryption alone was not sufficient to prevent this attack, and what additional security measures are needed to protect sensitive communications.]{.mark}

# Cleanup

When you are finished with the lab:

1. On **Mallory**, use Ctrl+C to stop Ettercap and both `arpspoof` processes.
2. On the **AP**, use Ctrl+C to stop `hostapd` or `create_ap`.
3. On **Alice**, **Bob**, and **Mallory**, run `killall wpa_supplicant` to stop any running WPA supplicant processes.
4. From the **testbed console**, power off the nodes:

```
omf tell -a off -t node1-1.sb4.orbit-lab.org,node1-2.sb4.orbit-lab.org,node1-7.sb4.orbit-lab.org,node1-8.sb4.orbit-lab.org
```

5. Log out of all SSH sessions.

# Sample Results (Part 1 Reference)

The following sample Wireshark screenshots illustrate the expected results for Part 1. Your own results should be similar.

**Open WiFi Network:** A passive sniffer can read any traffic sent over an open network. Notice the plaintext message visible in the data pane:

![Open WiFi - Plaintext Visible](figures/fig_sample_open_plaintext.png)

*Figure 6: Open WiFi capture -- the secret message is visible in plaintext.*

**WEP Network (before adding key):** The data appears encrypted and unreadable:

![WEP - Encrypted](figures/fig_sample_wep_encrypted.png)

*Figure 7: WEP capture without decryption key -- data is encrypted.*

**WEP Network (after adding key):** After adding the WEP key (`31:32:33:34:35`), the same frame is now decrypted. Note the "Decrypted WEP data" tab at the bottom:

![WEP - Decrypted](figures/fig_sample_wep_decrypted.png)

*Figure 8: WEP capture with decryption key -- the secret message is now readable.*

**WPA Network (without 4-way handshake):** Even with the correct WPA key, the data remains encrypted because the 4-way handshake was not captured:

![WPA - Encrypted (no handshake)](figures/fig_sample_wpa_encrypted.png)

*Figure 9: WPA capture with key but without 4-way handshake -- data remains encrypted.*

**WPA Network (with 4-way handshake):** When Mallory captures the 4-way handshake AND has the WPA key, she can decrypt the traffic. Note the "Decrypted TKIP data" tab at the bottom:

![WPA - Decrypted (with handshake)](figures/fig_sample_wpa_decrypted.png)

*Figure 10: WPA capture with key and 4-way handshake -- the secret message is now readable.*

# Conclusion

After completing both parts, you should be able to explain:

- Why open WiFi networks provide no confidentiality for transmitted data.
- Why WEP encryption is insufficient (the key alone allows decryption).
- Why WPA encryption is stronger but requires the 4-way handshake for decryption.
- How ARP spoofing allows MiTM attacks even on WPA-protected networks.
- Why application-layer encryption (SFTP, SSH) is essential for protecting credentials on any WiFi network.
