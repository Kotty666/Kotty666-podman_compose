# frozen_string_literal: true

require 'spec_helper'

describe 'podman_compose' do
  on_supported_os.each do |os, os_facts|
    context "on #{os}" do
      let(:facts) { os_facts }

      it { is_expected.to compile.with_all_deps }
      it { is_expected.to contain_class('podman_compose::install') }
      it { is_expected.to contain_package('podman') }

      context 'with a project defined' do
        let(:params) do
          {
            'projects' => {
              'demo' => {
                'rootless' => false,
                'compose'  => {
                  'services' => {
                    'web' => { 'image' => 'nginx:1.27' },
                  },
                },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__project('demo') }
      end

      context 'with a cron project defined' do
        let(:params) do
          {
            'cron_projects' => {
              'job' => {
                'rootless'    => false,
                'on_calendar' => 'daily',
                'compose'     => {
                  'services' => {
                    'task' => { 'image' => 'busybox:latest' },
                  },
                },
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__cron('job') }
      end

      context 'with an autoscaler defined' do
        let(:params) do
          {
            'autoscalers' => {
              'api' => {
                'rootless' => false,
                'service'  => 'api',
              },
            },
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_podman_compose__autoscale('api') }
      end

      context 'dns_sync (default enabled)' do
        it { is_expected.to contain_class('podman_compose::dns_sync') }
        it { is_expected.to contain_file('/usr/local/libexec/podman-dns-sync.py').with_ensure('file').with_mode('0755') }
        it { is_expected.to contain_file('/etc/podman-compose/dns-sync.d').with_purge(true) }
        it { is_expected.to contain_service('podman-dns-sync.path').with_ensure('running').with_enable(true) }
        it { is_expected.to contain_service('podman-dns-sync.timer').with_ensure('running').with_enable(true) }

        it do
          is_expected.to contain_file('/etc/systemd/system/podman-dns-sync.path')
            .with_content(%r{^PathChanged=/etc/resolv\.conf$})
            .with_content(%r{^PathChanged=/run/systemd/resolve/resolv\.conf$})
        end

        it do
          is_expected.to contain_file('/etc/systemd/system/podman-dns-sync.timer')
            .with_content(%r{^OnUnitActiveSec=5min$})
        end

        it do
          is_expected.to contain_file('/usr/local/libexec/podman-dns-sync.py')
            .with_content(%r{^RESTART_AARDVARK = True$})
        end
      end

      context 'dns_sync with custom settings' do
        let(:params) do
          {
            'dns_sync_watch_paths'      => ['/run/NetworkManager/resolv.conf'],
            'dns_sync_interval'         => '1min',
            'dns_sync_restart_aardvark' => false,
          }
        end

        it { is_expected.to compile.with_all_deps }

        it do
          is_expected.to contain_file('/etc/systemd/system/podman-dns-sync.path')
            .with_content(%r{^PathChanged=/run/NetworkManager/resolv\.conf$})
            .without_content(%r{PathChanged=/etc/resolv\.conf})
        end

        it { is_expected.to contain_file('/etc/systemd/system/podman-dns-sync.timer').with_content(%r{^OnUnitActiveSec=1min$}) }
        it { is_expected.to contain_file('/usr/local/libexec/podman-dns-sync.py').with_content(%r{^RESTART_AARDVARK = False$}) }
      end

      context 'dns_sync disabled' do
        let(:params) { { 'dns_sync' => false } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/usr/local/libexec/podman-dns-sync.py').with_ensure('absent') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-dns-sync.service').with_ensure('absent') }
        it { is_expected.to contain_service('podman-dns-sync.path').with_ensure('stopped').with_enable(false) }
        it { is_expected.to contain_service('podman-dns-sync.timer').with_ensure('stopped').with_enable(false) }
      end

      context 'image_prune (default disabled)' do
        it { is_expected.to contain_class('podman_compose::image_prune') }
        it { is_expected.to contain_file('/etc/podman-compose/image-prune.d').with_purge(true) }
        it { is_expected.to contain_file('/usr/local/libexec/podman-image-prune.py').with_ensure('absent') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-image-prune.service').with_ensure('absent') }
        it { is_expected.to contain_file('/etc/systemd/system/podman-image-prune.timer').with_ensure('absent') }
        it { is_expected.to contain_service('podman-image-prune.timer').with_ensure('stopped').with_enable(false) }
      end

      context 'image_prune enabled, orphaned images only' do
        let(:params) { { 'image_prune' => true } }

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_service('podman-image-prune.timer').with_ensure('running').with_enable(true) }

        it do
          is_expected.to contain_file('/usr/local/libexec/podman-image-prune.py')
            .with_ensure('file')
            .with_mode('0755')
            .with_content(%r{^KEEP = None$})
            .with_content(%r{^DRY_RUN = False$})
        end

        it do
          is_expected.to contain_file('/etc/systemd/system/podman-image-prune.timer')
            .with_content(%r{^OnCalendar=daily$})
            .with_content(%r{^RandomizedDelaySec=1h$})
        end

        it do
          is_expected.to contain_file('/etc/systemd/system/podman-image-prune.service')
            .with_content(%r{^ExecStart=/usr/bin/python3 /usr/local/libexec/podman-image-prune.py$})
        end
      end

      context 'image_prune enabled, keep newest versions' do
        let(:params) do
          {
            'image_prune'                      => true,
            'image_prune_keep'                 => 3,
            'image_prune_on_calendar'          => 'Sun *-*-* 03:00:00',
            'image_prune_randomized_delay_sec' => '0',
            'image_prune_dry_run'              => true,
          }
        end

        it { is_expected.to compile.with_all_deps }
        it { is_expected.to contain_file('/usr/local/libexec/podman-image-prune.py').with_content(%r{^KEEP = 3$}) }
        it { is_expected.to contain_file('/usr/local/libexec/podman-image-prune.py').with_content(%r{^DRY_RUN = True$}) }
        it { is_expected.to contain_file('/etc/systemd/system/podman-image-prune.timer').with_content(%r{^OnCalendar=Sun \*-\*-\* 03:00:00$}) }
        it { is_expected.to contain_file('/etc/systemd/system/podman-image-prune.timer').with_content(%r{^RandomizedDelaySec=0$}) }
      end

      context 'image_prune_keep must be positive' do
        let(:params) { { 'image_prune' => true, 'image_prune_keep' => 0 } }

        it { is_expected.to compile.and_raise_error(%r{image_prune_keep}) }
      end
    end
  end
end
