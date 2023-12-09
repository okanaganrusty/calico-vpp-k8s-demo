# K8s and Calico VPP

<!-- toc -->

- [K8s and Calico VPP](#k8s-and-calico-vpp)
  - [Prerequistes](#prerequistes)
    - [Virtual Machine Configuration](#virtual-machine-configuration)
    - [Kubernetes Networks](#kubernetes-networks)
  - [Installation](#installation)
    - [Initialization of the kubernetes cluster](#initialization-of-the-kubernetes-cluster)
      - [On the k8s-master](#on-the-k8s-master)
      - [On the k8s-worker](#on-the-k8s-worker)
      - [On your workstation](#on-your-workstation)
        - [Install the kube configuration](#install-the-kube-configuration)
        - [Install kubectl and calicoctl](#install-kubectl-and-calicoctl)
        - [Install k9s](#install-k9s)
    - [Install Calico](#install-calico)
  - [Verification](#verification)

<!-- tocstop -->

## Prerequistes

- Basic working knowledge of kubernetes.
- Fully functional qemu (kvm) environment.
- IP network for your pods and service networks.

### Virtual Machine Configuration

- Linux host, running qemu-kvm, and gobgpd (IBGP AS 65535)
  - enp4s0: Unnumbered interface (`192.168.1.100/24`, gateway: `192.168.1.254`)
  - virbr0: RFC 1918 network (`172.16.0.0/23`)
    - Using static DHCP to assign addresses to our VM hosts
      - k8s-master1 receives the address `172.16.0.10`
      - k8s-worker1 receives the address `172.16.0.20`

- VM: `k8s-master`: Kubernetes control node
- VM: `k8s-worker`: Kubernetes worker node (optional)
  - If you don't have the resources to provision another VM, you can untaint the kubernetes `k8s-master` and allow it to run other deployments outside of the `kube-system` and `calico-system` namespaces.

### Kubernetes Networks

- In our kubernetes deployment, we will be using

  - `10.10.0.0/23` for our pods
  - `10.10.2.0/23` for our services

## Installation

### Initialization of the kubernetes cluster

#### On the k8s-master

```bash
# If you have already initialized a cluster, you don't need to do this,
# if you want to start a clean cluster (you will loose all your existing
# resources).
#
# sudo kubeadm reset
sudo systemctl daemon-reload

# Stop kubelet if it's already active, our ansible enables this for us on boot automatically.
# without needing to rebuild the VM.  We'll stop the kubelet until we've provisioned our new
# cluster.
sudo systemctl is-active kubelet && sudo systemctl stop kubelet

# Pull the images ahead of time that k8s will be using to build and operate the cluster.
sudo kubeadm config images pull

# Initialization of the cluster
sudo kubeadm init --pod-network-cidr=10.10.0.0/23 --service-cidr=10.10.2.0/23

mkdir -p $HOME/.kube

sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# If you are running on a single VM (without a worker, untaint your control node)
# Optional: kubectl taint nodes --all node-role.kubernetes.io/control-plane-
# Optional: kubectl taint nodes --all node-role.kubernetes.io/master-
```

#### On the k8s-worker

Copy the `kubeadm join` command from the `k8s-master` node, to join the two instances.

  > If you have already lost this or the token has expired, run the command `kubeadm token create --print-join-command` on the `k8s-master` and it will generate a new token to join the cluster.

```bash
kubeadm join 172.16.0.10:6443 \
  --token [token] \
  --discovery-token-ca-cert-hash sha256:[sha256 hash]
```

Once you've join the node to the cluster, from both nodes, you should be able to run `kubectl get nodes -o wide` and see that both nodes are aware of eachothers existence.

#### On your workstation

##### Install the kube configuration

Copy the `${HOME}/.kube/config` from the K8s master node to your local machine.  This'll allow you to control the cluster without needing to remain logged into either of the `k8s-master` or `k8s-worker` instances.

```bash
mkdir -p $HOME/.kube

umask 027
scp k8s-master1:.kube/config $HOME/.kube/config
```

##### Install kubectl and calicoctl

When installing both `kubectl` and `calicoctl` make sure you choose the version that aligns with the kubernetes cluster that you've deployed.  To find this out, run `kubectl get nodes` on one of your current nodes.

- Download and install `kubectl` from [https://kubernetes.io/docs/tasks/tools/](https://kubernetes.io/docs/tasks/tools/)
- Download and install `calicoctl` from [https://docs.tigera.io/calico/latest/operations/calicoctl/install](https://docs.tigera.io/calico/latest/operations/calicoctl/install)

##### Install k9s

- Download k9s at [https://github.com/derailed/k9s/releases](https://github.com/derailed/k9s/releases)

  > TUI's make everything better.  This makes for a little bit less typing when looking at the current cluster configuration.  K9s is a tool that will allow you to navigate in a text-based interface to manage your current kubernetes context.

### Install Calico

1. Create a manifests directory

```bash
mkdir -p calico-vpp/manifests
cd calico-vpp/manifests
```

1. Download the manifests for the calico and calico-vpp installations

```bash
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/tigera-operator.yaml
curl -O https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/custom-resources.yaml
curl -O https://raw.githubusercontent.com/projectcalico/vpp-dataplane/v3.26.0/yaml/generated/calico-vpp-nohuge.yaml
```

1. Edit and then apply the tigera, custom resources and installation default manifests

    - Edit `calico-vpp-nohuge.yaml` and update the interface and service prefix

    - Edit `custom-resources.yaml` and update the IP pools to match our IP pools for our pods

    ```yaml
    apiVersion: operator.tigera.io/v1
    kind: Installation
    metadata:
      name: default
    spec:
      # Configures Calico networking.
      calicoNetwork:
        # Note: The ipPools section cannot be modified post-install.
        ipPools:
        - blockSize: 28
          cidr: 10.10.0.0/23
          encapsulation: VXLANCrossSubnet
          natOutgoing: Enabled
          nodeSelector: all()
    ```

    - Create the `tigera-operator.yaml`

    ```bash
    kubectl create -f tigera-operator.yaml
    ```

    - Create the `custom-resources.yaml`

    ```bash
    kubectl create -f custom-resources.yaml
    ```

    - Create the `calico-vpp-nohuge.yaml`

    ```bash
    kubectl create -f calico-vpp-nohuge.yaml
    ```

2. Check the pods have all been started by the operator (which starts a deployment); you should see that the tigera-operator deployment is available and up-to-date.

```bash
kubectl get deployments -n tigera-operator
```

1. Apply the calico-vpp manifest (we are not supporting hugepages; hugepage support requires 512 x 2MB pages)

```bash
# Edit the current config maps (after the installation)
#
# * Update the CALICO_VPP_INTERFACES section
#       ...
#       "uplinkInterfaces": [{ "interfaceName": "enp7s0", "vppDriver": "af_packet" }]
#       ...
#
# * Update the SERVICE_PREFIX, to 10.10.2.0/23

kubectl edit configmap -n calico-vpp-dataplane calico-vpp-config
```

1. Edit the current installation config map (tigera installation)

```bash
# Edit the installation
#
# * Update `linuxDataplane` to be `VPP` (adjust in a previous step)

kubectl edit installation default
```

1. Create a simple gobgp configuration on our Linux host (assuming we're using a Debian/Ubuntu distribution with a gobgpd apt package)

```bash
sudo apt install -y gobgpd

cat <<'EOF'>/etc/gobgpd.conf
[global.config]
    as = 65535
    router-id = "172.16.0.1"
    port = 179

    [global.apply-policy.config]
        default-import-policy = "accept-route"
        default-export-policy = "accept-route"

[[peer-groups]]
  [peer-groups.config]
    peer-group-name = "peer-group"
    peer-as = 65535
  [[peer-groups.afi-safis]]
    [peer-groups.afi-safis.config]
      afi-safi-name = "ipv4-unicast"

[[dynamic-neighbors]]
  [dynamic-neighbors.config]
    prefix = "172.16.0.0/16"
    peer-group = "peer-group"
EOF

# If the service is already running, we'll restart it
sudo systemctl try-restart gobgpd.service
```

1. Create our calico felix configuration

```bash
cat <<'EOF'>felix-config-default.yaml
apiVersion: projectcalico.org/v3
kind: FelixConfiguration
metadata:
    name: default
spec:
    bpfLogLevel: ""
    floatingIPs: Disabled
    healthPort: 9099
    logSeverityScreen: Info
    reportingInterval: 0s
EOF

kubectl apply -f felix-config-default.yaml
```

2. Optionally, add the IP pools for calico to assign pod IPs

This IP pool is automatically created for us.  If we wanted to rename it, or change the properties of the IP pools assigned to nodes.

```bash
cat <<'EOF'>calico-vpp-ippools.yaml
apiVersion: projectcalico.org/v3
kind: IPPoolList
items:
- apiVersion: projectcalico.org/v3
  kind: IPPool
  metadata:
    name: ippool-10-10-0-0-23
  spec:
    blockSize: 28
    cidr: 10.10.0.0/23
    ipipMode: Never
    nodeSelector: all()
    vxlanMode: Never
EOF

calicoctl apply --filename calico-vpp-ippools.yaml
```

1. Create our BGP configuration for peering.  This'll allow us to announce individual CIDRs to our pods to the Linux host.

  > While we shouldn't really ever connect directly to a pod through it's IP, rather using a service.  This is just for our lab purposes.  We will also be disabling the node-to-node mesh functionality so that all traffic must pass through our Linux router.

```bash
cat <<'EOF'>bgp-configuration-default.yaml
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 65535
  bindMode: NodeIP
  listenPort: 179
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: false
  serviceClusterIPs:
  - cidr: 10.10.2.0/23
EOF

calicoctl apply --allow-version-mismatch --filename bgp-configuration-default.yaml
```

1. Create our global BGP peer (our Linux host)

```bash
cat <<'EOF'>bgp-peer-global-peer.yaml
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: global-peer
spec:
  asNumber: 65535
  peerIP: 172.16.0.1
EOF

calicoctl apply --allow-version-mismatch --filename bgp-peer-global-peer.yaml
```

## Verification

You should now have a working K8s cluster running VPP.
