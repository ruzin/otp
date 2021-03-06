%%
%% %CopyrightBegin%
%%
%% Copyright Ericsson AB 2007-2012. All Rights Reserved.
%%
%% The contents of this file are subject to the Erlang Public License,
%% Version 1.1, (the "License"); you may not use this file except in
%% compliance with the License. You should have received a copy of the
%% Erlang Public License along with this software. If not, it can be
%% retrieved online at http://www.erlang.org/.
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and limitations
%% under the License.
%%
%% %CopyrightEnd%
%%

%%
%%----------------------------------------------------------------------
%% Purpose: Handles tls1 encryption.
%%----------------------------------------------------------------------

-module(ssl_tls1).

-include("ssl_cipher.hrl").
-include("ssl_internal.hrl").
-include("ssl_record.hrl").

-export([master_secret/4, finished/5, certificate_verify/3, mac_hash/7,
	 setup_keys/8, suites/1, prf/5]).

%%====================================================================
%% Internal application API
%%====================================================================

-spec master_secret(integer(), binary(), binary(), binary()) -> binary().

master_secret(PrfAlgo, PreMasterSecret, ClientRandom, ServerRandom) ->
    %% RFC 2246 & 4346 && RFC 5246 - 8.1 %% master_secret = PRF(pre_master_secret,
    %%                                      "master secret", ClientHello.random +
    %%                                      ServerHello.random)[0..47];

    prf(PrfAlgo, PreMasterSecret, <<"master secret">>,
	[ClientRandom, ServerRandom], 48).

-spec finished(client | server, integer(), integer(), binary(), [binary()]) -> binary().

finished(Role, Version, PrfAlgo, MasterSecret, Handshake)
  when Version == 1; Version == 2; PrfAlgo == ?MD5SHA ->
    %% RFC 2246 & 4346 - 7.4.9. Finished
    %% struct {
    %%          opaque verify_data[12];
    %%      } Finished;
    %%
    %%      verify_data
    %%          PRF(master_secret, finished_label, MD5(handshake_messages) +
    %%          SHA-1(handshake_messages)) [0..11];
    MD5 = crypto:md5(Handshake),
    SHA = crypto:sha(Handshake),
    prf(?MD5SHA, MasterSecret, finished_label(Role), [MD5, SHA], 12);

finished(Role, Version, PrfAlgo, MasterSecret, Handshake)
  when Version == 3 ->
    %% RFC 5246 - 7.4.9. Finished
    %% struct {
    %%          opaque verify_data[12];
    %%      } Finished;
    %%
    %%      verify_data
    %%          PRF(master_secret, finished_label, Hash(handshake_messages)) [0..11];
    Hash = crypto:hash(mac_algo(PrfAlgo), Handshake),
    prf(PrfAlgo, MasterSecret, finished_label(Role), Hash, 12).

-spec certificate_verify(md5sha | sha, integer(), [binary()]) -> binary().

certificate_verify(md5sha, _Version, Handshake) ->
    MD5 = crypto:md5(Handshake),
    SHA = crypto:sha(Handshake),
    <<MD5/binary, SHA/binary>>;

certificate_verify(HashAlgo, _Version, Handshake) ->
    crypto:hash(HashAlgo, Handshake).

-spec setup_keys(integer(), integer(), binary(), binary(), binary(), integer(),
		 integer(), integer()) -> {binary(), binary(), binary(),
					  binary(), binary(), binary()}.  

setup_keys(Version, _PrfAlgo, MasterSecret, ServerRandom, ClientRandom, HashSize,
	   KeyMatLen, IVSize)
  when Version == 1 ->
    %% RFC 2246 - 6.3. Key calculation
    %% key_block = PRF(SecurityParameters.master_secret,
    %%                      "key expansion",
    %%                      SecurityParameters.server_random +
    %%                      SecurityParameters.client_random);
    %% Then the key_block is partitioned as follows:
    %%  client_write_MAC_secret[SecurityParameters.hash_size]
    %%  server_write_MAC_secret[SecurityParameters.hash_size]
    %%  client_write_key[SecurityParameters.key_material_length]
    %%  server_write_key[SecurityParameters.key_material_length]
    %%  client_write_IV[SecurityParameters.IV_size]
    %%  server_write_IV[SecurityParameters.IV_size]
    WantedLength = 2 * (HashSize + KeyMatLen + IVSize),
    KeyBlock = prf(?MD5SHA, MasterSecret, "key expansion",
		   [ServerRandom, ClientRandom], WantedLength),
    <<ClientWriteMacSecret:HashSize/binary, 
     ServerWriteMacSecret:HashSize/binary,
     ClientWriteKey:KeyMatLen/binary, ServerWriteKey:KeyMatLen/binary,
     ClientIV:IVSize/binary, ServerIV:IVSize/binary>> = KeyBlock,
    {ClientWriteMacSecret, ServerWriteMacSecret, ClientWriteKey,
     ServerWriteKey, ClientIV, ServerIV};

%% TLS v1.1
setup_keys(Version, _PrfAlgo, MasterSecret, ServerRandom, ClientRandom, HashSize,
	   KeyMatLen, IVSize)
  when Version == 2 ->
    %% RFC 4346 - 6.3. Key calculation
    %% key_block = PRF(SecurityParameters.master_secret,
    %%                      "key expansion",
    %%                      SecurityParameters.server_random +
    %%                      SecurityParameters.client_random);
    %% Then the key_block is partitioned as follows:
    %%  client_write_MAC_secret[SecurityParameters.hash_size]
    %%  server_write_MAC_secret[SecurityParameters.hash_size]
    %%  client_write_key[SecurityParameters.key_material_length]
    %%  server_write_key[SecurityParameters.key_material_length]
    %%
    %% RFC 4346 is incomplete, the client and server IVs have to
    %% be generated just like for TLS 1.0
    WantedLength = 2 * (HashSize + KeyMatLen + IVSize),
    KeyBlock = prf(?MD5SHA, MasterSecret, "key expansion",
		   [ServerRandom, ClientRandom], WantedLength),
    <<ClientWriteMacSecret:HashSize/binary,
     ServerWriteMacSecret:HashSize/binary,
     ClientWriteKey:KeyMatLen/binary, ServerWriteKey:KeyMatLen/binary,
     ClientIV:IVSize/binary, ServerIV:IVSize/binary>> = KeyBlock,
    {ClientWriteMacSecret, ServerWriteMacSecret, ClientWriteKey,
     ServerWriteKey, ClientIV, ServerIV};

%% TLS v1.2
setup_keys(Version, PrfAlgo, MasterSecret, ServerRandom, ClientRandom, HashSize,
	   KeyMatLen, IVSize)
  when Version == 3 ->
    %% RFC 5246 - 6.3. Key calculation
    %% key_block = PRF(SecurityParameters.master_secret,
    %%                      "key expansion",
    %%                      SecurityParameters.server_random +
    %%                      SecurityParameters.client_random);
    %% Then the key_block is partitioned as follows:
    %%  client_write_MAC_secret[SecurityParameters.hash_size]
    %%  server_write_MAC_secret[SecurityParameters.hash_size]
    %%  client_write_key[SecurityParameters.key_material_length]
    %%  server_write_key[SecurityParameters.key_material_length]
    %%  client_write_IV[SecurityParameters.fixed_iv_length]
    %%  server_write_IV[SecurityParameters.fixed_iv_length]
    WantedLength = 2 * (HashSize + KeyMatLen + IVSize),
    KeyBlock = prf(PrfAlgo, MasterSecret, "key expansion",
		   [ServerRandom, ClientRandom], WantedLength),
    <<ClientWriteMacSecret:HashSize/binary,
     ServerWriteMacSecret:HashSize/binary,
     ClientWriteKey:KeyMatLen/binary, ServerWriteKey:KeyMatLen/binary,
     ClientIV:IVSize/binary, ServerIV:IVSize/binary>> = KeyBlock,
    {ClientWriteMacSecret, ServerWriteMacSecret, ClientWriteKey,
     ServerWriteKey, ClientIV, ServerIV}.

-spec mac_hash(integer(), binary(), integer(), integer(), tls_version(),
	       integer(), binary()) -> binary(). 

mac_hash(Method, Mac_write_secret, Seq_num, Type, {Major, Minor}, 
	 Length, Fragment) ->
    %% RFC 2246 & 4346 - 6.2.3.1.
    %% HMAC_hash(MAC_write_secret, seq_num + TLSCompressed.type +
    %%              TLSCompressed.version + TLSCompressed.length +
    %%              TLSCompressed.fragment));
    Mac = hmac_hash(Method, Mac_write_secret, 
		    [<<?UINT64(Seq_num), ?BYTE(Type), 
		      ?BYTE(Major), ?BYTE(Minor), ?UINT16(Length)>>, 
		     Fragment]),
    Mac.

-spec suites(1|2|3) -> [cipher_suite()].
    
suites(Minor) when Minor == 1; Minor == 2->
    [ 
      ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA,
      ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA,
      ?TLS_RSA_WITH_AES_256_CBC_SHA,
      ?TLS_DHE_RSA_WITH_3DES_EDE_CBC_SHA,
      ?TLS_DHE_DSS_WITH_3DES_EDE_CBC_SHA,
      ?TLS_RSA_WITH_3DES_EDE_CBC_SHA,
      ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA,
      ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA,
      ?TLS_RSA_WITH_AES_128_CBC_SHA,
      %%?TLS_RSA_WITH_IDEA_CBC_SHA,
      ?TLS_RSA_WITH_RC4_128_SHA,
      ?TLS_RSA_WITH_RC4_128_MD5,
      ?TLS_DHE_RSA_WITH_DES_CBC_SHA,
      ?TLS_RSA_WITH_DES_CBC_SHA
     ];

suites(Minor) when Minor == 3 ->
    [
     ?TLS_DHE_RSA_WITH_AES_256_CBC_SHA256,
     ?TLS_DHE_DSS_WITH_AES_256_CBC_SHA256,
     ?TLS_RSA_WITH_AES_256_CBC_SHA256,
     ?TLS_DHE_RSA_WITH_AES_128_CBC_SHA256,
     ?TLS_DHE_DSS_WITH_AES_128_CBC_SHA256,
     ?TLS_RSA_WITH_AES_128_CBC_SHA256
     %% ?TLS_DH_anon_WITH_AES_128_CBC_SHA256,
     %% ?TLS_DH_anon_WITH_AES_256_CBC_SHA256
	] ++ suites(2).

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
%%%% HMAC and the Pseudorandom Functions RFC 2246 & 4346 - 5.%%%%
hmac_hash(?NULL, _, _) ->
    <<>>;
hmac_hash(?MD5, Key, Value) ->
    crypto:md5_mac(Key, Value);
hmac_hash(?SHA, Key, Value) ->
    crypto:sha_mac(Key, Value);
hmac_hash(?SHA256, Key, Value) ->
    crypto:sha256_mac(Key, Value);
hmac_hash(?SHA384, Key, Value) ->
    crypto:sha384_mac(Key, Value);
hmac_hash(?SHA512, Key, Value) ->
    crypto:sha512_mac(Key, Value).

mac_algo(?MD5)    -> md5;
mac_algo(?SHA)    -> sha;
mac_algo(?SHA256) -> sha256;
mac_algo(?SHA384) -> sha384;
mac_algo(?SHA512) -> sha512.

% First, we define a data expansion function, P_hash(secret, data) that
% uses a single hash function to expand a secret and seed into an
% arbitrary quantity of output:
%% P_hash(secret, seed) = HMAC_hash(secret, A(1) + seed) +
%%                        HMAC_hash(secret, A(2) + seed) +
%%                        HMAC_hash(secret, A(3) + seed) + ...

p_hash(Secret, Seed, WantedLength, Method) ->
    p_hash(Secret, Seed, WantedLength, Method, 0, []).

p_hash(_Secret, _Seed, WantedLength, _Method, _N, [])
  when WantedLength =< 0 ->
    [];
p_hash(_Secret, _Seed, WantedLength, _Method, _N, [Last | Acc])
  when WantedLength =< 0 ->
    Keep = byte_size(Last) + WantedLength,
    <<B:Keep/binary, _/binary>> = Last,
    list_to_binary(lists:reverse(Acc, [B]));
p_hash(Secret, Seed, WantedLength, Method, N, Acc) ->
    N1 = N+1,
    Bin = hmac_hash(Method, Secret, [a(N1, Secret, Seed, Method), Seed]),
    p_hash(Secret, Seed, WantedLength - byte_size(Bin), Method, N1, [Bin|Acc]).


%% ... Where  A(0) = seed
%%            A(i) = HMAC_hash(secret, A(i-1))
%% a(0, _Secret, Seed, _Method) -> 
%%     Seed.
%% a(N, Secret, Seed, Method) ->
%%     hmac_hash(Method, Secret, a(N-1, Secret, Seed, Method)).
a(0, _Secret, Seed, _Method) ->
    Seed;
a(N, Secret, Seed0, Method) ->
    Seed = hmac_hash(Method, Secret, Seed0),
    a(N-1, Secret, Seed, Method).

split_secret(BinSecret) ->
    %% L_S = length in bytes of secret;
    %% L_S1 = L_S2 = ceil(L_S / 2);
    %% The secret is partitioned into two halves (with the possibility of
    %% one shared byte) as described above, S1 taking the first L_S1 bytes,
    %% and S2 the last L_S2 bytes.
    Length = byte_size(BinSecret),
    Div = Length div 2,
    EvenLength = Length - Div,
    <<Secret1:EvenLength/binary, _/binary>> = BinSecret,
    <<_:Div/binary, Secret2:EvenLength/binary>> = BinSecret,
    {Secret1, Secret2}.

prf(?MD5SHA, Secret, Label, Seed, WantedLength) ->
    %% PRF(secret, label, seed) = P_MD5(S1, label + seed) XOR
    %%                            P_SHA-1(S2, label + seed);
    {S1, S2} = split_secret(Secret),
    LS = list_to_binary([Label, Seed]),
    crypto:exor(p_hash(S1, LS, WantedLength, ?MD5),
		p_hash(S2, LS, WantedLength, ?SHA));

prf(MAC, Secret, Label, Seed, WantedLength) ->
    %% PRF(secret, label, seed) = P_SHA256(secret, label + seed);
    LS = list_to_binary([Label, Seed]),
    p_hash(Secret, LS, WantedLength, MAC).

%%%% Misc help functions %%%%

finished_label(client) ->
    <<"client finished">>;
finished_label(server) ->
    <<"server finished">>.
